atchannel.c                                                                                         0000644 0001750 0001750 00000106774 12271742740 013034  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#include "atchannel.h"
#include "at_tok.h"

#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <ctype.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <stdarg.h>

#include <poll.h>

#define LOG_NDEBUG 0
#define LOG_TAG "AT"
#include <utils/Log.h>

#ifdef HAVE_ANDROID_OS
/* For IOCTL's */
#include <linux/omap_csmi.h>
#endif /*HAVE_ANDROID_OS*/

#include "misc.h"

#define MAX_AT_RESPONSE (8 * 1024)
#define HANDSHAKE_RETRY_COUNT 8
#define HANDSHAKE_TIMEOUT_MSEC 250
#define DEFAULT_AT_TIMEOUT_MSEC (3 * 60 * 1000)
#define BUFFSIZE 512

struct atcontext {
    pthread_t tid_reader;
    int fd;                  /* fd of the AT channel. */
    int readerCmdFds[2];
    int isInitialized;
    ATUnsolHandler unsolHandler;

    /* For input buffering. */
    char ATBuffer[MAX_AT_RESPONSE+1];
    char *ATBufferCur;

    int readCount;

    /*
     * For current pending command, these are protected by commandmutex.
     *
     * The mutex and cond struct is memset in the getAtChannel() function,
     * so no initializer should be needed.
     */
    pthread_mutex_t requestmutex;
    pthread_mutex_t commandmutex;
    pthread_cond_t requestcond;
    pthread_cond_t commandcond;

    ATCommandType type;
    const char *responsePrefix;
    const char *smsPDU;
    ATResponse *response;

    void (*onTimeout)(void);
    void (*onReaderClosed)(void);
    int readerClosed;

    int timeoutMsec;
};

static struct atcontext *s_defaultAtContext = NULL;
static va_list empty = {0};

static pthread_key_t key;
static pthread_once_t key_once = PTHREAD_ONCE_INIT;

static int writeCtrlZ (const char *s);
static int writeline (const char *s);
static void onReaderClosed(void);

static void make_key(void)
{
    (void) pthread_key_create(&key, NULL);
}

/**
 * Set the atcontext pointer. Useful for sub-threads that needs to hold
 * the same state information.
 *
 * The caller IS responsible for freeing any memory already allocated
 * for any previous atcontexts.
 */
static void setAtContext(struct atcontext *ac)
{
    (void) pthread_once(&key_once, make_key);
    (void) pthread_setspecific(key, ac);
}

static void ac_free(void)
{
    struct atcontext *ac = NULL;
    (void) pthread_once(&key_once, make_key);
    if ((ac = pthread_getspecific(key)) != NULL) {
        free(ac);
        ALOGD("%s() freed current thread AT context", __func__);
    } else {
        ALOGW("%s() No AT context exist for current thread, cannot free it",
            __func__);
    }
}

static int initializeAtContext(void)
{
    struct atcontext *ac = NULL;

    if (pthread_once(&key_once, make_key)) {
        ALOGE("%s() Pthread_once failed!", __func__);
        goto error;
    }

    ac = pthread_getspecific(key);

    if (ac == NULL) {
        ac = malloc(sizeof(struct atcontext));
        if (ac == NULL) {
            ALOGE("%s() Failed to allocate memory", __func__);
            goto error;
        }

        memset(ac, 0, sizeof(struct atcontext));

        ac->fd = -1;
        ac->readerCmdFds[0] = -1;
        ac->readerCmdFds[1] = -1;
        ac->ATBufferCur = ac->ATBuffer;

        if (pipe(ac->readerCmdFds)) {
            ALOGE("%s() Failed to create pipe: %s", __func__, strerror(errno));
            goto error;
        }

        pthread_mutex_init(&ac->commandmutex, NULL);
        pthread_mutex_init(&ac->requestmutex, NULL);
        pthread_cond_init(&ac->requestcond, NULL);
        pthread_cond_init(&ac->commandcond, NULL);

        ac->timeoutMsec = DEFAULT_AT_TIMEOUT_MSEC;

        if (pthread_setspecific(key, ac)) {
            ALOGE("%s() Calling pthread_setspecific failed!", __func__);
            goto error;
        }
    }

    ALOGI("Initialized new AT Context!");

    return 0;

error:
    ALOGE("%s() Failed initializing new AT Context!", __func__);
    free(ac);
    return -1;
}

static struct atcontext *getAtContext(void)
{
    struct atcontext *ac = NULL;

    (void) pthread_once(&key_once, make_key);

    if ((ac = pthread_getspecific(key)) == NULL) {
        if (s_defaultAtContext) {
            ALOGW("WARNING! external thread use default AT Context");
            ac = s_defaultAtContext;
        } else {
            ALOGE("WARNING! %s() called from external thread with "
                 "no defaultAtContext set!! This IS a bug! "
                 "A crash is probably nearby!", __func__);
        }
    } 

    return ac;
}

/**
 * This function will make the current at thread the default channel,
 * meaning that calls from a thread that is not a queuerunner will
 * be executed in this context.
 */
void at_make_default_channel(void)
{
    struct atcontext *ac = getAtContext();

    if (ac->isInitialized)
        s_defaultAtContext = ac;
}

#if AT_DEBUG
void  AT_DUMP(const char*  prefix, const char*  buff, int  len)
{
    if (len < 0)
        len = strlen(buff);
    ALOGD("%.*s", len, buff);
}
#endif

#ifndef HAVE_ANDROID_OS
int pthread_cond_timeout_np(pthread_cond_t *cond,
                            pthread_mutex_t * mutex,
                            unsigned msecs)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    ts.tv_sec += msecs / 1000;
    ts.tv_nsec += (msecs % 1000) * 1000000;
    return pthread_cond_timedwait(cond, mutex, &ts);
}
#endif /*HAVE_ANDROID_OS*/

static void sleepMsec(long long msec)
{
    struct timespec ts;
    int err;

    ts.tv_sec = (msec / 1000);
    ts.tv_nsec = (msec % 1000) * 1000 * 1000;

    do {
        err = nanosleep (&ts, &ts);
    } while (err < 0 && errno == EINTR);
}



/** Add an intermediate response to sp_response. */
static void addIntermediate(const char *line)
{
    ATLine *p_new;
    struct atcontext *ac = getAtContext();

    p_new = (ATLine  *) malloc(sizeof(ATLine));

    p_new->line = strdup(line);

    /* Note: This adds to the head of the list, so the list will
       be in reverse order of lines received. the order is flipped
       again before passing on to the command issuer. */
    p_new->p_next = ac->response->p_intermediates;
    ac->response->p_intermediates = p_new;
}


/**
 * Returns 1 if line is a final response indicating error.
 * See 27.007 annex B.
 * WARNING: NO CARRIER and others are sometimes unsolicited.
 */
static const char * s_finalResponsesError[] = {
    "ERROR",
    "+CMS ERROR:",
    "+CME ERROR:",
    "NO CARRIER",      /* Sometimes! */
    "NO ANSWER",
    "NO DIALTONE",
};
static int isFinalResponseError(const char *line)
{
    size_t i;

    for (i = 0 ; i < NUM_ELEMS(s_finalResponsesError) ; i++) {
        if (strStartsWith(line, s_finalResponsesError[i])) {
            return 1;
        }
    }

    return 0;
}

/**
 * Returns 1 if line is a final response indicating success.
 * See 27.007 annex B.
 * WARNING: NO CARRIER and others are sometimes unsolicited.
 */
static const char * s_finalResponsesSuccess[] = {
    "OK",
    "CONNECT"       /* Some stacks start up data on another channel. */
};
static int isFinalResponseSuccess(const char *line)
{
    size_t i;

    for (i = 0 ; i < NUM_ELEMS(s_finalResponsesSuccess) ; i++) {
        if (strStartsWith(line, s_finalResponsesSuccess[i])) {
            return 1;
        }
    }

    return 0;
}

/**
 * Returns 1 if line is the first line in (what will be) a two-line
 * SMS unsolicited response.
 */
static const char * s_smsUnsoliciteds[] = {
    "+CMT:",
    "+CDS:",
    "+CBM:"
};
static int isSMSUnsolicited(const char *line)
{
    size_t i;

    for (i = 0 ; i < NUM_ELEMS(s_smsUnsoliciteds) ; i++) {
        if (strStartsWith(line, s_smsUnsoliciteds[i])) {
            return 1;
        }
    }

    return 0;
}


/** Assumes s_commandmutex is held. */
static void handleFinalResponse(const char *line)
{
    struct atcontext *ac = getAtContext();

    ac->response->finalResponse = strdup(line);

    pthread_cond_signal(&ac->commandcond);
}

static void handleUnsolicited(const char *line)
{
    struct atcontext *ac = getAtContext();

    if (ac->unsolHandler != NULL) {
        ac->unsolHandler(line, NULL);
    }
}

static void processLine(const char *line)
{
    struct atcontext *ac = getAtContext();
    pthread_mutex_lock(&ac->commandmutex);

    if (ac->response == NULL) {
        /* No command pending. */
        handleUnsolicited(line);
    } else if (isFinalResponseSuccess(line)) {
        ac->response->success = 1;
        handleFinalResponse(line);
    } else if (isFinalResponseError(line)) {
        ac->response->success = 0;
        handleFinalResponse(line);
    } else if (ac->smsPDU != NULL && 0 == strcmp(line, "> ")) {
        /* See eg. TS 27.005 4.3.
           Commands like AT+CMGS have a "> " prompt. */
        writeCtrlZ(ac->smsPDU);
        ac->smsPDU = NULL;
    } else switch (ac->type) {
        case NO_RESULT:
            handleUnsolicited(line);
            break;
        case NUMERIC:
            if (ac->response->p_intermediates == NULL
                && isdigit(line[0])) {
                addIntermediate(line);
            } else {
                /* Either we already have an intermediate response or
                   the line doesn't begin with a digit. */
                handleUnsolicited(line);
            }
            break;
        case SINGLELINE:
            if (ac->response->p_intermediates == NULL
                && strStartsWith (line, ac->responsePrefix)) {
                addIntermediate(line);
            } else {
                /* We already have an intermediate response. */
                handleUnsolicited(line);
            }
            break;
        case MULTILINE:
            if (strStartsWith (line, ac->responsePrefix)) {
                addIntermediate(line);
            } else {
                handleUnsolicited(line);
            }
        break;

        default: /* This should never be reached */
            ALOGE("%s() Unsupported AT command type %d", __func__, ac->type);
            handleUnsolicited(line);
        break;
    }

    pthread_mutex_unlock(&ac->commandmutex);
}


/**
 * Returns a pointer to the end of the next line,
 * special-cases the "> " SMS prompt.
 *
 * returns NULL if there is no complete line.
 */
static char * findNextEOL(char *cur)
{
    if (cur[0] == '>' && cur[1] == ' ' && cur[2] == '\0') {
        /* SMS prompt character...not \r terminated */
        return cur+2;
    }

    /* Find next newline */
    while (*cur != '\0' && *cur != '\r' && *cur != '\n') cur++;

    return *cur == '\0' ? NULL : cur;
}


/**
 * Reads a line from the AT channel, returns NULL on timeout.
 * Assumes it has exclusive read access to the FD.
 *
 * This line is valid only until the next call to readline.
 *
 * This function exists because as of writing, android libc does not
 * have buffered stdio.
 */

static const char *readline(void)
{
    ssize_t count;

    char *p_read = NULL;
    char *p_eol = NULL;
    char *ret = NULL;

    struct atcontext *ac = getAtContext();
    read(ac->fd,NULL,0);

    /* This is a little odd. I use *s_ATBufferCur == 0 to mean
     * "buffer consumed completely". If it points to a character,
     * then the buffer continues until a \0.
     */
    if (*ac->ATBufferCur == '\0') {
        /* Empty buffer. */
        ac->ATBufferCur = ac->ATBuffer;
        *ac->ATBufferCur = '\0';
        p_read = ac->ATBuffer;
    } else {   /* *s_ATBufferCur != '\0' */
        /* There's data in the buffer from the last read. */

        /* skip over leading newlines */
        while (*ac->ATBufferCur == '\r' || *ac->ATBufferCur == '\n')
            ac->ATBufferCur++;

        p_eol = findNextEOL(ac->ATBufferCur);

        if (p_eol == NULL) {
            /* A partial line. Move it up and prepare to read more. */
            size_t len;

            len = strlen(ac->ATBufferCur);

            memmove(ac->ATBuffer, ac->ATBufferCur, len + 1);
            p_read = ac->ATBuffer + len;
            ac->ATBufferCur = ac->ATBuffer;
        }
        /* Otherwise, (p_eol !- NULL) there is a complete line 
           that will be returned from the while () loop below. */
    }

    while (p_eol == NULL) {
        int err;
        struct pollfd pfds[2];

        /* This condition should be synchronized with the read function call
         * size argument below.
         */
        if (0 >= MAX_AT_RESPONSE - (p_read - ac->ATBuffer) - 2) {
            ALOGE("%s() ERROR: Input line exceeded buffer", __func__);
            /* Ditch buffer and start over again. */
            ac->ATBufferCur = ac->ATBuffer;
            *ac->ATBufferCur = '\0';
            p_read = ac->ATBuffer;
        }

        /* If our fd is invalid, we are probably closed. Return. */
        if (ac->fd < 0)
            return NULL;

        pfds[0].fd = ac->fd;
        pfds[0].events = POLLIN | POLLERR;

        pfds[1].fd = ac->readerCmdFds[0];
        pfds[1].events = POLLIN;

        err = poll(pfds, 2, -1);

        if (err < 0) {
            ALOGE("%s() poll: error: %s", __func__, strerror(errno));
            return NULL;
        }

        if (pfds[1].revents & POLLIN) {
            char buf[10];

            /* Just drain it. We don't care, this is just for waking up. */
            read(pfds[1].fd, &buf, 1);
            continue;
        }

        if (pfds[0].revents & POLLERR) {
            ALOGE("%s() POLLERR event! Returning...", __func__);
            return NULL;
        }

        if (!(pfds[0].revents & POLLIN))
            continue;

        do
            /* The size argument should be synchronized to the ditch buffer
             * condition above.
             */
            count = read(ac->fd, p_read,
                         MAX_AT_RESPONSE - (p_read - ac->ATBuffer) - 2);

        while (count < 0 && errno == EINTR);

        if (count > 0) {
            AT_DUMP( "<< ", p_read, count );
            ac->readCount += count;

            /* Implementation requires extra EOS or EOL to get it right if
             * there are no trailing newlines in the read buffer. Adding extra
             * EOS does not harm even if there actually were trailing EOLs.
             */
            p_read[count] = '\0';
            p_read[count+1] = '\0';

            /* Skip over leading newlines. */
            while (*ac->ATBufferCur == '\r' || *ac->ATBufferCur == '\n')
                ac->ATBufferCur++;

            p_eol = findNextEOL(ac->ATBufferCur);
            p_read += count;
        } else if (count <= 0) {
            /* Read error encountered or EOF reached. */
            if (count == 0)
                ALOGD("%s() atchannel: EOF reached.", __func__);
            else
                ALOGD("%s() atchannel: read error %s", __func__, strerror(errno));

            return NULL;
        }
    }

    /* A full line in the buffer. Place a \0 over the \r and return. */

    ret = ac->ATBufferCur;
    *p_eol = '\0';

    /* The extra EOS added after read takes care of the case when there is no
     * valid data after p_eol.
     */
    ac->ATBufferCur = p_eol + 1;     /* This will always be <= p_read,    
                                        and there will be a \0 at *p_read. */

    ALOGI("AT(%d)< %s", ac->fd, ret);
    return ret;
}

static void onReaderClosed(void)
{
    struct atcontext *ac = getAtContext();
    if (ac->onReaderClosed != NULL && ac->readerClosed == 0) {

        pthread_mutex_lock(&ac->commandmutex);

        ac->readerClosed = 1;

        pthread_cond_signal(&ac->commandcond);

        pthread_mutex_unlock(&ac->commandmutex);

        ac->onReaderClosed();
    }
}

static void *readerLoop(void *arg)
{
    struct atcontext *ac = NULL;

    ALOGI("Entering readerloop!");

    setAtContext((struct atcontext *) arg);
    ac = getAtContext();

    for (;;) {
        const char * line;

        line = readline();

        if (line == NULL)
            break;

        if(isSMSUnsolicited(line)) {
            char *line1;
            const char *line2;

            /* The scope of string returned by 'readline()' is valid only
               until next call to 'readline()' hence making a copy of line
               before calling readline again. */
            line1 = strdup(line);
            line2 = readline();

            if (line2 == NULL) {
                free(line1);
                break;
            }

            if (ac->unsolHandler != NULL)
                ac->unsolHandler(line1, line2);

            free(line1);
        } else
            processLine(line);
    }

    onReaderClosed();
    ALOGI("Exiting readerloop!");
    return NULL;
}

/**
 * Sends string s to the radio with a \r appended.
 * Returns AT_ERROR_* on error, 0 on success.
 *
 * This function exists because as of writing, android libc does not
 * have buffered stdio.
 */
static int writeline (const char *s)
{
    size_t cur = 0;
    size_t len = strlen(s);
    char *cmd;
    ssize_t written;

    struct atcontext *ac = getAtContext();

    if (ac->fd < 0 || ac->readerClosed > 0) {
        return AT_ERROR_CHANNEL_CLOSED;
    }

    ALOGD("AT(%d)> %s", ac->fd, s);

    AT_DUMP( ">> ", s, strlen(s) );

    if (!(asprintf(&cmd, "%s\r", s))) {
        ALOGE("%s() Failed to allocate string", __func__);
        return AT_ERROR_GENERIC;
    }

    len++;

    /* The whole string. */
    while (cur < len) {
        do {
            written = write (ac->fd, cmd + cur, len - cur);
        } while (written < 0 && errno == EINTR);

        if (written < 0) {
            free(cmd);
            return AT_ERROR_GENERIC;
        }

        cur += written;
    }

    free(cmd);

    return 0;
}

static int writeCtrlZ (const char *s)
{
    size_t cur = 0;
    size_t len = strlen(s);
    char *cmd;
    ssize_t written;

    struct atcontext *ac = getAtContext();

    if (ac->fd < 0 || ac->readerClosed > 0)
        return AT_ERROR_CHANNEL_CLOSED;

    ALOGD("AT> %s^Z\n", s);

    AT_DUMP( ">* ", s, strlen(s) );

    if (!(asprintf(&cmd, "%s\032", s))) {
        ALOGE("%s() Failed to allocate string", __func__);
        return AT_ERROR_GENERIC;
    }

    len++;

    /* The whole string. */
    while (cur < len) {
        do {
            written = write (ac->fd, cmd + cur, len - cur);
        } while (written < 0 && errno == EINTR);

        if (written < 0) {
            free(cmd);
            return AT_ERROR_GENERIC;
        }

        cur += written;
    }

    free(cmd);

    return 0;
}

static void clearPendingCommand(void)
{
    struct atcontext *ac = getAtContext();

    if (ac->response != NULL)
        at_response_free(ac->response);

    ac->response = NULL;
    ac->responsePrefix = NULL;
    ac->smsPDU = NULL;
}

static int merror(int type, int error)
{
    switch(type) {
    case AT_ERROR :
        return AT_ERROR_BASE + error;
    case CME_ERROR :
        return CME_ERROR_BASE + error;
    case CMS_ERROR:
        return CMS_ERROR_BASE + error;
    case GENERIC_ERROR:
        return GENERIC_ERROR_BASE + error;
    default:
        return GENERIC_ERROR_UNSPECIFIED;
    }
}

static AT_Error at_get_error(const ATResponse *p_response)
{
    int ret;
    int err;
    char *p_cur;

    if (p_response == NULL)
        return merror(GENERIC_ERROR, GENERIC_ERROR_UNSPECIFIED);

    if (p_response->success > 0)
        return AT_NOERROR;

    if (p_response->finalResponse == NULL)
        return AT_ERROR_INVALID_RESPONSE;


    if (isFinalResponseSuccess(p_response->finalResponse))
        return AT_NOERROR;

    p_cur = p_response->finalResponse;
    err = at_tok_start(&p_cur);
    if (err < 0)
        return merror(GENERIC_ERROR, GENERIC_ERROR_UNSPECIFIED);

    err = at_tok_nextint(&p_cur, &ret);
    if (err < 0)
        return merror(GENERIC_ERROR, GENERIC_ERROR_UNSPECIFIED);

    if(strStartsWith(p_response->finalResponse, "+CME ERROR:"))
        return merror(CME_ERROR, ret);
    else if (strStartsWith(p_response->finalResponse, "+CMS ERROR:"))
        return merror(CMS_ERROR, ret);
    else if (strStartsWith(p_response->finalResponse, "ERROR:"))
        return merror(GENERIC_ERROR, GENERIC_ERROR_RESPONSE);
    else if (strStartsWith(p_response->finalResponse, "+NO CARRIER:"))
        return merror(GENERIC_ERROR, GENERIC_NO_CARRIER_RESPONSE);
    else if (strStartsWith(p_response->finalResponse, "+NO ANSWER:"))
        return merror(GENERIC_ERROR, GENERIC_NO_ANSWER_RESPONSE);
    else if (strStartsWith(p_response->finalResponse, "+NO DIALTONE:"))
        return merror(GENERIC_ERROR, GENERIC_NO_DIALTONE_RESPONSE);
    else
        return merror(GENERIC_ERROR, GENERIC_ERROR_UNSPECIFIED);
}

/**
 * Starts AT handler on stream "fd'.
 * returns 0 on success, -1 on error.
 */
int at_open(int fd, ATUnsolHandler h)
{
    int ret;
    pthread_attr_t attr;

    struct atcontext *ac = NULL;

    if (initializeAtContext()) {
        ALOGE("%s() InitializeAtContext failed!", __func__);
        goto error;
    }
    
    ac = getAtContext();

    ac->fd = fd;
    ac->isInitialized = 1;
    ac->unsolHandler = h;
    ac->readerClosed = 0;

    ac->responsePrefix = NULL;
    ac->smsPDU = NULL;
    ac->response = NULL;

    pthread_attr_init (&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);

    ret = pthread_create(&ac->tid_reader, &attr, readerLoop, ac);

    if (ret < 0) {
        perror ("pthread_create");
        goto error;
    }


    return 0;
error:
    ac_free();
    return -1;
}

/* FIXME is it ok to call this from the reader and the command thread? */
void at_close(void)
{
    struct atcontext *ac = getAtContext();

    if (ac->fd >= 0) {
        if (close(ac->fd) != 0)
            ALOGE("%s() FAILED to close fd %d!", __func__, ac->fd);
        ac->fd = -1;
    } else {
        ALOGW("%s() Already closed!", __func__);
        return;
    }

    pthread_mutex_lock(&ac->commandmutex);

    ac->readerClosed = 1;

    pthread_cond_signal(&ac->commandcond);

    pthread_mutex_unlock(&ac->commandmutex);

    /* Kick readerloop. */
    write(ac->readerCmdFds[1], "x", 1);
}

static ATResponse *at_response_new(void)
{
    return (ATResponse *) calloc(1, sizeof(ATResponse));
}

void at_response_free(ATResponse *p_response)
{
    ATLine *p_line;

    if (p_response == NULL) return;

    p_line = p_response->p_intermediates;

    while (p_line != NULL) {
        ATLine *p_toFree;

        p_toFree = p_line;
        p_line = p_line->p_next;

        free(p_toFree->line);
        free(p_toFree);
    }

    free (p_response->finalResponse);
    free (p_response);
}

/**
 * The line reader places the intermediate responses in reverse order,
 * here we flip them back.
 */
static void reverseIntermediates(ATResponse *p_response)
{
    ATLine *pcur,*pnext;

    pcur = p_response->p_intermediates;
    p_response->p_intermediates = NULL;

    while (pcur != NULL) {
        pnext = pcur->p_next;
        pcur->p_next = p_response->p_intermediates;
        p_response->p_intermediates = pcur;
        pcur = pnext;
    }
}

/**
 * Internal send_command implementation.
 * Doesn't lock or call the timeout callback.
 *
 * timeoutMsec == 0 means infinite timeout.
 */
static int at_send_command_full_nolock (const char *command, ATCommandType type,
                    const char *responsePrefix, const char *smspdu,
                    long long timeoutMsec, ATResponse **pp_outResponse)
{
    int err = AT_NOERROR;

    struct atcontext *ac = getAtContext();

    /* Default to NULL, to allow caller to free securely even if
     * no response will be set below */
    if (pp_outResponse != NULL)
        *pp_outResponse = NULL;

    /* FIXME This is to prevent future problems due to calls from other threads; should be revised. */
    while (pthread_mutex_trylock(&ac->requestmutex) == EBUSY)
        pthread_cond_wait(&ac->requestcond, &ac->commandmutex);

    if(ac->response != NULL) {
        err = AT_ERROR_COMMAND_PENDING;
        goto finally;
    }

    ac->type = type;
    ac->responsePrefix = responsePrefix;
    ac->smsPDU = smspdu;
    ac->response = at_response_new();
    if (ac->response == NULL) {
        err = AT_ERROR_MEMORY_ALLOCATION;
        goto finally;
    }

    err = writeline (command);

    if (err != AT_NOERROR)
        goto finally;

    while (ac->response->finalResponse == NULL && ac->readerClosed == 0) {
        if (timeoutMsec != 0)
            err = pthread_cond_timeout_np(&ac->commandcond, &ac->commandmutex, timeoutMsec);
        else
            err = pthread_cond_wait(&ac->commandcond, &ac->commandmutex);

        if (err == ETIMEDOUT) {
            err = AT_ERROR_TIMEOUT;
            goto finally;
        }
    }

    if (ac->response->success == 0) {
        err = at_get_error(ac->response);
    }

    if (pp_outResponse == NULL)
        at_response_free(ac->response);
    else {
        /* Line reader stores intermediate responses in reverse order. */
        reverseIntermediates(ac->response);
        *pp_outResponse = ac->response;
    }

    ac->response = NULL;

    if(ac->readerClosed > 0) {
        err = AT_ERROR_CHANNEL_CLOSED;
        goto finally;
    }

finally:
    clearPendingCommand();

    pthread_cond_broadcast(&ac->requestcond);
    pthread_mutex_unlock(&ac->requestmutex);

    return err;
}

/**
 * Internal send_command implementation.
 *
 * timeoutMsec == 0 means infinite timeout.
 */
static int at_send_command_full (const char *command, ATCommandType type,
                    const char *responsePrefix, const char *smspdu,
                    long long timeoutMsec, ATResponse **pp_outResponse, int useap, va_list ap)
{
    int err;

    struct atcontext *ac = getAtContext();
    static char strbuf[BUFFSIZE];
    const char *ptr;

    if (0 != pthread_equal(ac->tid_reader, pthread_self()))
        /* Cannot be called from reader thread. */
        return AT_ERROR_INVALID_THREAD;

    pthread_mutex_lock(&ac->commandmutex);
    if (useap) {
        if (!vsnprintf(strbuf, BUFFSIZE, command, ap)) {
           pthread_mutex_unlock(&ac->commandmutex);
           return AT_ERROR_STRING_CREATION;
        }
        ptr = strbuf;
    } else
        ptr = command;

    err = at_send_command_full_nolock(ptr, type,
                    responsePrefix, smspdu,
                    timeoutMsec, pp_outResponse);

    pthread_mutex_unlock(&ac->commandmutex);

    if (err == AT_ERROR_TIMEOUT && ac->onTimeout != NULL)
        ac->onTimeout();

    return err;
}

/* Only call this from onTimeout, since we're not locking or anything. */
void at_send_escape (void)
{
    struct atcontext *ac = getAtContext();
    int written;

    do
        written = write (ac->fd, "\033" , 1);
    while ((written < 0 && errno == EINTR) || (written == 0));
}

/**
 * Issue a single normal AT command with no intermediate response expected.
 *
 * "command" should not include \r.
 */
int at_send_command (const char *command, ...)
{
    int err;

    struct atcontext *ac = getAtContext();
    va_list ap;
    va_start(ap, command);

    err = at_send_command_full (command, NO_RESULT, NULL,
            NULL, ac->timeoutMsec, NULL, 1, ap);
    va_end(ap);

    if (err != AT_NOERROR)
        ALOGI(" --- %s", at_str_err(-err));

    return -err;
}

int at_send_command_raw (const char *command, ATResponse **pp_outResponse)
{
    struct atcontext *ac = getAtContext();
    int err;

    err = at_send_command_full (command, MULTILINE, "",
            NULL, ac->timeoutMsec, pp_outResponse, 0, empty);

    /* Don't check for intermediate responses as it is unknown if any
     * intermediate responses are expected. Don't free the response, instead,
     * let calling function free the allocated response.
     */

    if (err != AT_NOERROR)
        ALOGI(" --- %s", at_str_err(-err));

    return -err;
}

int at_send_command_singleline (const char *command,
                                const char *responsePrefix,
                                 ATResponse **pp_outResponse, ...)
{
    int err;

    struct atcontext *ac = getAtContext();
    va_list ap;
    va_start(ap, pp_outResponse);

    err = at_send_command_full (command, SINGLELINE, responsePrefix,
                                    NULL, ac->timeoutMsec, pp_outResponse, 1, ap);

    if (err == AT_NOERROR && pp_outResponse != NULL
            && (*pp_outResponse) != NULL
            && (*pp_outResponse)->p_intermediates == NULL)
        /* Command with pp_outResponse must have an intermediate response */
        err = AT_ERROR_INVALID_RESPONSE;

    /* Free response in case of error */
    if (err != AT_NOERROR && pp_outResponse != NULL
            && (*pp_outResponse) != NULL) {
        at_response_free(*pp_outResponse);
        *pp_outResponse = NULL;
    }

    va_end(ap);

    if (err != AT_NOERROR)
        ALOGI(" --- %s", at_str_err(-err));

    return -err;
}

int at_send_command_numeric (const char *command,
                                 ATResponse **pp_outResponse)
{
    int err;

    struct atcontext *ac = getAtContext();

    err = at_send_command_full (command, NUMERIC, NULL,
                                NULL, ac->timeoutMsec, pp_outResponse, 0, empty);

    if (err == AT_NOERROR && pp_outResponse != NULL
            && (*pp_outResponse) != NULL
            && (*pp_outResponse)->p_intermediates == NULL)
        /* Command with pp_outResponse must have an intermediate response */
        err = AT_ERROR_INVALID_RESPONSE;

    /* Free response in case of error */
    if (err != AT_NOERROR && pp_outResponse != NULL
            && (*pp_outResponse) != NULL) {
        at_response_free(*pp_outResponse);
        *pp_outResponse = NULL;
    }

    if (err != AT_NOERROR)
        ALOGI(" --- %s", at_str_err(-err));

    return -err;
}


int at_send_command_sms (const char *command,
                                const char *pdu,
                                const char *responsePrefix,
                                 ATResponse **pp_outResponse)
{
    int err;

    struct atcontext *ac = getAtContext();

    err = at_send_command_full (command, SINGLELINE, responsePrefix,
                                    pdu, ac->timeoutMsec, pp_outResponse, 0, empty);

    if (err == AT_NOERROR && pp_outResponse != NULL
            && (*pp_outResponse) != NULL
            && (*pp_outResponse)->p_intermediates == NULL)
        /* Command with pp_outResponse must have an intermediate response */
        err = AT_ERROR_INVALID_RESPONSE;

    /* Free response in case of error */
    if (err != AT_NOERROR && pp_outResponse != NULL
            && (*pp_outResponse) != NULL) {
        at_response_free(*pp_outResponse);
        *pp_outResponse = NULL;
    }

    if (err != AT_NOERROR)
        ALOGI(" --- %s", at_str_err(-err));

    return -err;
}


int at_send_command_multiline (const char *command,
                                const char *responsePrefix,
                                 ATResponse **pp_outResponse, ...)
{
    int err;

    struct atcontext *ac = getAtContext();
    va_list ap;
    va_start(ap, pp_outResponse);

    err = at_send_command_full (command, MULTILINE, responsePrefix,
                                    NULL, ac->timeoutMsec, pp_outResponse, 1, ap);
    va_end(ap);

    if (err == AT_NOERROR && pp_outResponse != NULL
            && (*pp_outResponse) != NULL
            && (*pp_outResponse)->p_intermediates == NULL)
        /* Command with pp_outResponse must have an intermediate response */
        err = AT_ERROR_INVALID_RESPONSE;

    /* Free response in case of error */
    if (err != AT_NOERROR && pp_outResponse != NULL
            && (*pp_outResponse) != NULL) {
        at_response_free(*pp_outResponse);
        *pp_outResponse = NULL;
    }

    if (err != AT_NOERROR)
        ALOGI(" --- %s", at_str_err(-err));

    return -err;
}

/**
 * Set the default timeout. Let it be reasonably high, some commands
 * take their time.
 */
void at_set_timeout_msec(int timeout)
{
    struct atcontext *ac = getAtContext();

    ac->timeoutMsec = timeout;

    ALOGI("Setting AT command timeout to %d ms", timeout);
}

/** This callback is invoked on the command thread. */
void at_set_on_timeout(void (*onTimeout)(void))
{
    struct atcontext *ac = getAtContext();

    ac->onTimeout = onTimeout;
}


/*
 * This callback is invoked on the reader thread (like ATUnsolHandler), when the
 * input stream closes before you call at_close (not when you call at_close()).
 * You should still call at_close(). It may also be invoked immediately from the
 * current thread if the read channel is already closed.
 */
void at_set_on_reader_closed(void (*onClose)(void))
{
    struct atcontext *ac = getAtContext();

    ac->onReaderClosed = onClose;
}


/**
 * Periodically issue an AT command and wait for a response.
 * Used to ensure channel has start up and is active.
 */
int at_handshake(void)
{
    int i;
    int err = 0;

    struct atcontext *ac = getAtContext();

    if (0 != pthread_equal(ac->tid_reader, pthread_self()))
        /* Cannot be called from reader thread. */
        return AT_ERROR_INVALID_THREAD;

    pthread_mutex_lock(&ac->commandmutex);

    for (i = 0 ; i < HANDSHAKE_RETRY_COUNT ; i++) {
        /* Some stacks start with verbose off. */
        err = at_send_command_full_nolock ("ATE0V1", NO_RESULT,
                    NULL, NULL, HANDSHAKE_TIMEOUT_MSEC, NULL);

        if (err == 0)
            break;
    }

    if (err == 0) {
        /* Pause for a bit to let the input buffer drain any unmatched OK's
           (they will appear as extraneous unsolicited responses). */
        ALOGD("%s() pausing %d ms to drain unmatched OK's...",
             __func__, HANDSHAKE_TIMEOUT_MSEC);
        sleepMsec(HANDSHAKE_TIMEOUT_MSEC);
    }

    pthread_mutex_unlock(&ac->commandmutex);

    return err;
}

AT_Error at_get_at_error(int error)
{
    error = -error;
    if (error >= AT_ERROR_BASE && error < AT_ERROR_TOP)
        return error - AT_ERROR_BASE;
    else
        return AT_ERROR_NON_AT;
}

AT_CME_Error at_get_cme_error(int error)
{
    error = -error;
    if (error >= CME_ERROR_BASE && error < CME_ERROR_TOP)
        return error - CME_ERROR_BASE;
    else
        return CME_ERROR_NON_CME;
}

AT_CMS_Error at_get_cms_error(int error)
{
    error = -error;
    if (error >= CMS_ERROR_BASE && error < CMS_ERROR_TOP)
        return error - CMS_ERROR_BASE;
    else
        return CMS_ERROR_NON_CMS;
}

AT_Generic_Error at_get_generic_error(int error)
{
    error = -error;
    if (error >= GENERIC_ERROR_BASE && error < GENERIC_ERROR_TOP)
        return error - GENERIC_ERROR_BASE;
    else
        return GENERIC_ERROR_NON_GENERIC;
}

AT_Error_type at_get_error_type(int error)
{
    error = -error;
    if (error == AT_NOERROR)
        return NONE_ERROR;

    if (error > AT_ERROR_BASE && error <= AT_ERROR_TOP)
        return AT_ERROR;

    if (error >= CME_ERROR_BASE && error <= CME_ERROR_TOP)
        return CME_ERROR;

    if (error >= CMS_ERROR_BASE && error <= CMS_ERROR_TOP)
        return CMS_ERROR;

    if (error >= GENERIC_ERROR_BASE && error <= GENERIC_ERROR_TOP)
        return GENERIC_ERROR;

    return UNKNOWN_ERROR;
}

#define quote(x) #x

char *at_str_err(int error) {
    char *s = "--UNKNOWN--";

    error = -error;
    switch(error) {
#define AT(name, num) case num + AT_ERROR_BASE: s = quote(AT_##name); break;
#define CME(name, num) case num + CME_ERROR_BASE: s = quote(CME_##name); break;
#define CMS(name, num) case num + CMS_ERROR_BASE: s = quote(CMS_##name); break;
#define GENERIC(name, num) case num + GENERIC_ERROR_BASE: s = quote(GENERIC_##name); break;
    mbm_error
#undef AT
#undef CME
#undef CMS
#undef GENERIC
    }

    return s;
}
    atchannel.h                                                                                         0000644 0001750 0001750 00000012217 12271742740 013025  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#ifndef ATCHANNEL_H
#define ATCHANNEL_H 1
#include "at_error.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Define AT_DEBUG to send AT traffic to "/tmp/radio-at.log" */
#define AT_DEBUG  0

#if AT_DEBUG
extern void  AT_DUMP(const char* prefix, const char*  buff, int  len);
#else
#define  AT_DUMP(prefix,buff,len)  do{}while(0)
#endif

typedef enum {
    DEFAULT_VALUE = -1,
    GENERAL = 0,
    AUTHENTICATION_FAILURE = 1,
    IMSI_UNKNOWN_IN_HLR = 2,
    ILLEGAL_MS = 3,
    ILLEGAL_ME = 4,
    PLMN_NOT_ALLOWED = 5,
    LOCATION_AREA_NOT_ALLOWED = 6,
    ROAMING_NOT_ALLOWED = 7,
    NO_SUITABLE_CELL_IN_LOCATION_AREA = 8,
    NETWORK_FAILURE = 9,
    PERSISTEN_LOCATION_UPDATE_REJECT = 10
} CsReg_Deny_DetailReason;

typedef enum {
    GPRS_NOT_ALLOWED = 7,
    GPRS_NON_GPRS_NOT_ALLOWED = 8,
    MS_IDENTITY_UNKNOWN = 9,
    IMPLICITLY_DETACHED = 10,
    GPRS_NOT_ALLOWED_PLMN = 14,
    MSC_TEMPORARILY_UNAVAILABLE = 16,
    NO_PDP_CONTEXT_ACTIVATED = 40,
} PsReg_Deny_DetailReason;

typedef enum {
    NO_RESULT,      /* No intermediate response expected. */
    NUMERIC,        /* A single intermediate response starting with a 0-9. */
    SINGLELINE,     /* A single intermediate response starting with a prefix. */
    MULTILINE       /* Multiple line intermediate response
                       starting with a prefix. */
} ATCommandType;

/** A singly-linked list of intermediate responses. */
typedef struct ATLine  {
    struct ATLine *p_next;
    char *line;
} ATLine;

/** Free this with at_response_free(). */
typedef struct {
    int success;              /* True if final response indicates
                                 success (eg "OK"). */
    char *finalResponse;      /* Eg OK, ERROR */
    ATLine  *p_intermediates; /* Any intermediate responses. */
} ATResponse;

/**
 * A user-provided unsolicited response handler function.
 * This will be called from the reader thread, so do not block.
 * "s" is the line, and "sms_pdu" is either NULL or the PDU response
 * for multi-line TS 27.005 SMS PDU responses (eg +CMT:).
 */
typedef void (*ATUnsolHandler)(const char *s, const char *sms_pdu);

int at_open(int fd, ATUnsolHandler h);
void at_close(void);

/*
 * Set default timeout for at commands. Let it be reasonable high
 * since some commands take their time. Default is 10 minutes.
 */
void at_set_timeout_msec(int timeout);

/* 
 * This callback is invoked on the command thread.
 * You should reset or handshake here to avoid getting out of sync.
 */
void at_set_on_timeout(void (*onTimeout)(void));

/*
 * This callback is invoked on the reader thread (like ATUnsolHandler), when the
 * input stream closes before you call at_close (not when you call at_close()).
 * You should still call at_close(). It may also be invoked immediately from the
 * current thread if the read channel is already closed.
 */
void at_set_on_reader_closed(void (*onClose)(void));

void at_send_escape(void);

int at_send_command_singleline (const char *command,
                                const char *responsePrefix,
                                ATResponse **pp_outResponse,
                                ...);

int at_send_command_numeric (const char *command,
                             ATResponse **pp_outResponse);

int at_send_command_multiline (const char *command,
                               const char *responsePrefix,
                               ATResponse **pp_outResponse,
                               ...);


int at_handshake(void);

int at_send_command (const char *command, ...);

/* at_send_command_raw do allow missing intermediate response(s) without an
 * error code in the return value. Besides that, the response is not freed.
 * This requires the caller to handle freeing of the response, even in the
 * case that there was an error.
 */
int at_send_command_raw (const char *command, ATResponse **pp_outResponse);

int at_send_command_sms (const char *command, const char *pdu,
                            const char *responsePrefix,
                            ATResponse **pp_outResponse);

void at_response_free(ATResponse *p_response);

void at_make_default_channel(void);

AT_Error get_at_error(int error);
AT_CME_Error at_get_cme_error(int error);
AT_CMS_Error at_get_cms_error(int error);
AT_Generic_Error at_get_generic_error(int error);
AT_Error_type at_get_error_type(int error);
char *at_str_err(int error);

#ifdef __cplusplus
}
#endif

#endif
                                                                                                                                                                                                                                                                                                                                                                                 at_error.h                                                                                          0000644 0001750 0001750 00000021343 12271742740 012705  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                #ifndef ATERROR_H
#define ATERROR_H 1

#define mbm_error \
    at_error \
    cme_error \
    cms_error \
    generic_error \

#define at_error \
    aterror(AT, NOERROR, 0) \
    aterror(AT, ERROR_GENERIC, 1) \
    aterror(AT, ERROR_COMMAND_PENDING, 2) \
    aterror(AT, ERROR_CHANNEL_CLOSED, 3) \
    aterror(AT, ERROR_TIMEOUT, 4) \
    aterror(AT, ERROR_INVALID_THREAD, 5) \
    aterror(AT, ERROR_INVALID_RESPONSE, 6) \
    aterror(AT, ERROR_MEMORY_ALLOCATION, 7) \
    aterror(AT, ERROR_STRING_CREATION, 8) \

#define cme_error \
    aterror(CME, MODULE_FAILURE, 0) \
    aterror(CME, NO_MODULE_CONNECTION, 1) \
    aterror(CME, PHONE_ADAPTER_RESERVED, 2) \
    aterror(CME, OPERATION_NOT_ALLOWED, 3) \
    aterror(CME, OPERATION_NOT_SUPPORTED, 4) \
    aterror(CME, PH_SIM_PIN, 5) \
    aterror(CME, PH_FSIM_PIN, 6) \
    aterror(CME, PH_FSIM_PUK, 7) \
    aterror(CME, SIM_NOT_INSERTED, 10) \
    aterror(CME, SIM_PIN_REQUIRED, 11) \
    aterror(CME, SIM_PUK_REQUIRED, 12) \
    aterror(CME, FAILURE, 13) \
    aterror(CME, SIM_BUSY, 14) \
    aterror(CME, SIM_WRONG, 15) \
    aterror(CME, INCORRECT_PASSWORD, 16) \
    aterror(CME, SIM_PIN2_REQUIRED, 17) \
    aterror(CME, SIM_PUK2_REQUIRED, 18) \
    aterror(CME, MEMORY_FULL, 20) \
    aterror(CME, INVALID_INDEX, 21) \
    aterror(CME, NOT_FOUND, 22) \
    aterror(CME, MEMORY_FAILURE, 23) \
    aterror(CME, STRING_TO_LONG, 24) \
    aterror(CME, INVALID_CHAR, 25) \
    aterror(CME, DIALSTR_TO_LONG, 26) \
    aterror(CME, INVALID_DIALCHAR, 27) \
    aterror(CME, NO_NETWORK_SERVICE, 30) \
    aterror(CME, NETWORK_TIMEOUT, 31) \
    aterror(CME, NETWORK_NOT_ALLOWED, 32) \
    aterror(CME, NETWORK_PERSONALIZATION_PIN_REQUIRED, 40) \
    aterror(CME, NETWORK_PERSONALIZATION_PUK_REQUIRED, 41) \
    aterror(CME, NETWORK_SUBSET_PERSONALIZATION_PIN_REQUIRED, 42) \
    aterror(CME, NETWORK_SUBSET_PERSONALIZATION_PUK_REQUIRED, 43) \
    aterror(CME, SERVICE_PROVIDER_PERSONALIZATION_PIN_REQUIRED, 44) \
    aterror(CME, SERVICE_PROVIDER_PERSONALIZATION_PUK_REQUIRED, 45) \
    aterror(CME, CORPORATE_PERSONALIZATION_PIN_REQUIRED, 46) \
    aterror(CME, CORPORATE_PERSONALIZATION_PUK_REQUIRED, 47) \
    aterror(CME, HIDDEN_KEY, 48) \
    aterror(CME, EAP_NOT_SUPORTED, 49) \
    aterror(CME, INCORRECT_PARAMETERS, 50) \
    aterror(CME, UNKNOWN, 100) \
    aterror(CME, ILLEGAL_MS, 103) \
    aterror(CME, ILLEGAL_ME, 106) \
    aterror(CME, PLMN_NOT_ALLOWED, 111) \
    aterror(CME, LOCATION_AREA_NOT_ALLOWED, 112) \
    aterror(CME, ROAMING_AREA_NOT_ALLOWED, 113) \
    aterror(CME, SERVICE_NOT_SUPPORTED, 132) \
    aterror(CME, SERVICE_NOT_SUBSCRIBED, 133) \
    aterror(CME, SERVICE_TEMPORARILY_OUT, 134) \
    aterror(CME, UNSPECIFIED_GPRS_ERROR, 148) \
    aterror(CME, PDP_AUTH_FAILURE, 149) \
    aterror(CME, INVALID_MOBILE_CLASS, 150) \
    aterror(CME, PH_SIMLOCK_PIN_REQUIRED, 200) \
    aterror(CME, SYNTAX_ERROR, 257) \
    aterror(CME, INVALID_PARAMETER, 258) \
    aterror(CME, LENGTH_ERROR, 259) \
    aterror(CME, SIM_AUTH_FAILURE, 260) \
    aterror(CME, SIM_FILE_ERROR, 261) \
    aterror(CME, FILE_SYSTEM_ERROR, 262) \
    aterror(CME, SERVICE_UNAVIABLE, 263) \
    aterror(CME, PHONEBOOK_NOT_READY, 264) \
    aterror(CME, PHONEBOOK_NOT_SUPPORTED, 265) \
    aterror(CME, COMMAND_TO_LONG, 266) \
    aterror(CME, PARAMETER_OUT_OF_RANGE, 267) \
    aterror(CME, BAND_NOT_ALLOWED, 268) \
    aterror(CME, SUPPLEMENTARY_SERIVEC_FAILURE, 269) \
    aterror(CME, COMMAND_ABORTED, 270) \
    aterror(CME, ACTION_ALREADY_IN_PROGRESS, 271) \
    aterror(CME, WAN_DISABLED, 272) \
    aterror(CME, GPS_DISABLE_DUE_TO_TEMP, 273) \
    aterror(CME, RADIO_NOT_ACTIVATED, 274) \
    aterror(CME, USB_NOT_CONFIGURED, 275) \
    aterror(CME, NOT_CONNECTED, 276) \
    aterror(CME, NOT_DISCONNECTED, 277) \
    aterror(CME, TOO_MANY_CONNECTIONS, 278) \
    aterror(CME, TOO_MANY_USERS, 279) \
    aterror(CME, FDN_RESTRICITONS, 280) \

#define cms_error \
    aterror(CMS, UNASSIGNED_NUMBER, 1) \
    aterror(CMS, BARRING, 8) \
    aterror(CMS, CALL_BARRED, 10) \
    aterror(CMS, SHORT_MESSAGE_REJECTED, 21) \
    aterror(CMS, DESTINATION_OUT_OF_SERVICE, 27) \
    aterror(CMS, UNIDENTIFIED_SUBSCRIBER, 28) \
    aterror(CMS, FACILITY_REJECTED, 29) \
    aterror(CMS, UNKNOWN_SUBSCRIBER, 30) \
    aterror(CMS, NETWORK_OUT_OF_ORDER, 38) \
    aterror(CMS, TEMP_FAILURE, 41) \
    aterror(CMS, SMS_CONGESTION, 42) \
    aterror(CMS, RESOURCE_UNAVAIBLE, 47) \
    aterror(CMS, REQUESTED_FACILITY_NOT_SUBSCRIBED, 50) \
    aterror(CMS, REQUESTED_FACILITY_NOT_IMPLEMENTED, 69) \
    aterror(CMS, INVALID_SMS_REF, 81) \
    aterror(CMS, INVALID_MESSAGE, 95) \
    aterror(CMS, INVALID_MANDATORY_INFORMATION, 96) \
    aterror(CMS, MESSAGE_TYPE_NOT_IMPLEMENTED, 97) \
    aterror(CMS, MESSAGE_NOT_COMPATIBLE, 98) \
    aterror(CMS, INFORMATION_ELEMENT_NOT_IMPLEMENTED, 99) \
    aterror(CMS, PROTOCOL_ERROR, 111) \
    aterror(CMS, INTERWORKING_UNSPECIFIED, 127) \
    aterror(CMS, TELEMATIC_INTERWORKING_NOT_SUPPORTED, 128) \
    aterror(CMS, SHORT_MESSAGE_TYPE_0_NOT_SUPPORTED, 129) \
    aterror(CMS, CANNOT_REPLACE_SHORT_MESSAGE, 130) \
    aterror(CMS, UNSPECIFIED_TP_PID_ERROR, 143) \
    aterror(CMS, DATA_SCHEME_NOT_SUPPORTED, 144) \
    aterror(CMS, MESSAGE_CLASS_NOT_SUPPORTED, 145) \
    aterror(CMS, UNSPECIFIED_TP_DCS_ERROR, 159) \
    aterror(CMS, COMMAND_CANT_BE_ACTIONED, 160) \
    aterror(CMS, COMMAND_UNSUPPORTED, 161) \
    aterror(CMS, UNSPECIFIED_TP_COMMAND, 175) \
    aterror(CMS, TPDU_NOT_SUPPORTED, 176) \
    aterror(CMS, SC_BUSY, 192) \
    aterror(CMS, NO_SC_SUBSCRIPTINO, 193) \
    aterror(CMS, SC_FAILURE, 194) \
    aterror(CMS, INVALID_SME_ADDRESS, 195) \
    aterror(CMS, SME_BARRIED, 196) \
    aterror(CMS, SM_DUPLICATE_REJECTED, 197) \
    aterror(CMS, TP_VPF_NOT_SUPPORTED, 198) \
    aterror(CMS, TP_VP_NOT_SUPPORTED, 199) \
    aterror(CMS, SIM_SMS_FULL, 208) \
    aterror(CMS, NO_SMS_STORAGE_CAPABILITY, 209) \
    aterror(CMS, ERROR_IN_MS, 210) \
    aterror(CMS, MEMORY_CAPACITY_EXCEEDED, 211) \
    aterror(CMS, STK_BUSY, 212) \
    aterror(CMS, UNSPECIFIED_ERROR, 255) \
    aterror(CMS, ME_FAILURE, 300) \
    aterror(CMS, SMS_OF_ME_RESERVED, 301) \
    aterror(CMS, SERVICE_OPERATION_NOT_ALLOWED, 302) \
    aterror(CMS, SERVICE_OPERATION_NOT_SUPPORTED, 303) \
    aterror(CMS, INVALID_PDU_PARAMETER, 304) \
    aterror(CMS, INVALID_TEXT_PARAMETER, 305) \
    aterror(CMS, SERVICE_SIM_NOT_INSERTED, 310) \
    aterror(CMS, SERVICE_SIM_PIN_REQUIRED, 311) \
    aterror(CMS, PH_SIM_PIN_REQUIRED, 312) \
    aterror(CMS, SIM_FAILURE, 313) \
    aterror(CMS, SERVICE_SIM_BUSY, 314) \
    aterror(CMS, SERVICE_SIM_WRONG, 315) \
    aterror(CMS, SIM_PUK_REQUIRED, 316) \
    aterror(CMS, SERVICE_SIM_PIN2_REQUIRED, 317) \
    aterror(CMS, SERVICE_SIM_PUK2_REQUIRED, 318) \
    aterror(CMS, SERVICE_MEMORY_FAILURE, 320) \
    aterror(CMS, INVALID_MEMORY_INDEX, 321) \
    aterror(CMS, SERVICE_MEMORY_FULL, 322) \
    aterror(CMS, SMSC_ADDR_UNKNOWN, 330) \
    aterror(CMS, NO_NETWORK_SERVICE, 331) \
    aterror(CMS, NETWORK_TIMEOUT, 332) \
    aterror(CMS, NO_CNMA, 340) \
    aterror(CMS, UNKNOWN_ERROR, 500) \

#define generic_error \
    aterror(GENERIC, ERROR_RESPONSE, 1) \
    aterror(GENERIC, NO_CARRIER_RESPONSE, 2) \
    aterror(GENERIC, NO_ANSWER_RESPONSE, 3) \
    aterror(GENERIC, NO_DIALTONE_RESPONSE, 4) \
    aterror(GENERIC, ERROR_UNSPECIFIED, 5) \

#define aterror(group, name, num) group(name, num)

typedef enum {
    CME_ERROR_NON_CME = -1,
#define CME(name, num) CME_ ## name = num,
    cme_error
#undef CME
} AT_CME_Error;

typedef enum {
    CMS_ERROR_NON_CMS = -1,
#define CMS(name, num) CMS_ ## name = num,
    cms_error
#undef CMS
} AT_CMS_Error;

typedef enum {
    GENERIC_ERROR_NON_GENERIC = -1,
#define GENERIC(name, num) GENERIC_ ## name = num,
    generic_error
#undef GENERIC
} AT_Generic_Error;

typedef enum {
    AT_ERROR_NON_AT = -1,
    /* AT ERRORS are enumerated by MBM_Error below */
} AT_Error;

#define AT_ERROR_BASE          0 /* see also _TOP */
#define CME_ERROR_BASE      1000 /* see also _TOP */
#define CMS_ERROR_BASE      2000 /* see also _TOP */
#define GENERIC_ERROR_BASE  3000 /* see also _TOP */

#define AT_ERROR_TOP       (CME_ERROR_BASE - 1) /* see also _BASE */
#define CME_ERROR_TOP      (CMS_ERROR_BASE - 1) /* see also _BASE */
#define CMS_ERROR_TOP      (GENERIC_ERROR_BASE - 1) /* see also _BASE */
#define GENERIC_ERROR_TOP  (GENERIC_ERROR_BASE + 999) /* see also _BASE */

typedef enum {
#define AT(name, num) AT_ ## name = num + AT_ERROR_BASE,
#define CME(name, num) AT_CME_ ## name = num + CME_ERROR_BASE,
#define CMS(name, num) AT_CMS_ ## name = num + CMS_ERROR_BASE,
#define GENERIC(name, num) AT_GENERIC_ ## name = num + GENERIC_ERROR_BASE,
    mbm_error
#undef CME
#undef CMS
#undef GENERIC
#undef AT
} MBM_Error;

typedef enum {
    NONE_ERROR,
    AT_ERROR,
    CME_ERROR,
    CMS_ERROR,
    GENERIC_ERROR,
    UNKNOWN_ERROR,
} AT_Error_type;
#endif
                                                                                                                                                                                                                                                                                             at_tok.c                                                                                            0000644 0001750 0001750 00000012515 12271742740 012345  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* //device/system/reference-ril/at_tok.c
**
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
*/

#include "at_tok.h"
#include <string.h>
#include <ctype.h>
#include <stdlib.h>

/**
 * Starts tokenizing an AT response string.
 * Returns -1 if this is not a valid response string, 0 on success.
 * Updates *p_cur with current position.
 */
int at_tok_start(char **p_cur)
{
    if (*p_cur == NULL)
        return -1;

    /* Skip prefix,
       consume "^[^:]:". */

    *p_cur = strchr(*p_cur, ':');

    if (*p_cur == NULL)
        return -1;

    (*p_cur)++;

    return 0;
}

static void skipWhiteSpace(char **p_cur)
{
    if (*p_cur == NULL)
        return;

    while (**p_cur != '\0' && isspace(**p_cur))
        (*p_cur)++;
}

static void skipNextComma(char **p_cur)
{
    if (*p_cur == NULL)
        return;

    while (**p_cur != '\0' && **p_cur != ',')
        (*p_cur)++;

    if (**p_cur == ',')
        (*p_cur)++;
}

/**
 * If the first none space character is a quotation mark, returns the string
 * between two quotation marks, else returns the content before the first comma.
 * Updates *p_cur.
 */
static char *nextTok(char **p_cur)
{
    char *ret = NULL;

    skipWhiteSpace(p_cur);

    if (*p_cur == NULL) {
        ret = NULL;
    } else if (**p_cur == '"') {
        enum State {END, NORMAL, ESCAPE} state = NORMAL;

        (*p_cur)++;
        ret = *p_cur;

        while (state != END) {
            switch (state) {
            case NORMAL:
                switch (**p_cur) {
                case '\\':
                    state = ESCAPE;
                    break;
                case '"':
                    state = END;
                    break;
                case '\0':
                    /*
                     * Error case, parsing string is not quoted by ending
                     * double quote, e.g. "bla bla, this function expects input
                     * string to be NULL terminated, so that the loop can exit.
                     */
                    ret = NULL;
                    goto exit;
                default:
                    /* Stays in normal case. */
                    break;
                }
                break;

            case ESCAPE:
                state = NORMAL;
                break;

            default:
                /* This should never happen. */
                break;
            }

            if (state == END) {
                **p_cur = '\0';
            }

            (*p_cur)++;
        }
        skipNextComma(p_cur);
    } else {
        ret = strsep(p_cur, ",");
    }
exit:
    return ret;
}

/**
 * Parses the next integer in the AT response line and places it in *p_out.
 * Returns 0 on success and -1 on fail.
 * Updates *p_cur.
 * "base" is the same as the base param in strtol.
 */
static int at_tok_nextint_base(char **p_cur, int *p_out, int base, int  uns)
{
    char *ret;

    if (*p_cur == NULL)
        return -1;

    if (p_out == NULL)
        return -1;

    ret = nextTok(p_cur);

    if (ret == NULL)
        return -1;
    else {
        long l;
        char *end;

        if (uns)
            l = strtoul(ret, &end, base);
        else
            l = strtol(ret, &end, base);

        *p_out = (int)l;

        if (end == ret)
            return -1;
    }

    return 0;
}

/**
 * Parses the next base 10 integer in the AT response line
 * and places it in *p_out.
 * Returns 0 on success and -1 on fail.
 * Updates *p_cur.
 */
int at_tok_nextint(char **p_cur, int *p_out)
{
    return at_tok_nextint_base(p_cur, p_out, 10, 0);
}

/**
 * Parses the next base 16 integer in the AT response line 
 * and places it in *p_out.
 * Returns 0 on success and -1 on fail.
 * Updates *p_cur.
 */
int at_tok_nexthexint(char **p_cur, int *p_out)
{
    return at_tok_nextint_base(p_cur, p_out, 16, 1);
}

int at_tok_nextbool(char **p_cur, char *p_out)
{
    int ret;
    int result;

    ret = at_tok_nextint(p_cur, &result);

    if (ret < 0)
        return -1;

    /* Booleans should be 0 or 1. */
    if (!(result == 0 || result == 1))
        return -1;

    if (p_out != NULL)
        *p_out = (char)result;
    else
        return -1;

    return ret;
}

int at_tok_nextstr(char **p_cur, char **p_out)
{
    if (*p_cur == NULL)
        return -1;

    *p_out = nextTok(p_cur);
    if (*p_out == NULL)
        return -1;

    return 0;
}

/** Returns 1 on "has more tokens" and 0 if not. */
int at_tok_hasmore(char **p_cur)
{
    return ! (*p_cur == NULL || **p_cur == '\0');
}

/** *p_out returns count of given character (needle) in given string (p_in). */
int at_tok_charcounter(char *p_in, char needle, int *p_out)
{
    char *p_cur = p_in;
    int num_found = 0;

    if (p_in == NULL)
        return -1;

    while (*p_cur != '\0') {
        if (*p_cur == needle) {
            num_found++;
        }

        p_cur++;
    }

    *p_out = num_found;
    return 0;
}
                                                                                                                                                                                   at_tok.h                                                                                            0000644 0001750 0001750 00000001775 12271742740 012360  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* //device/system/reference-ril/at_tok.h
**
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
*/

#ifndef AT_TOK_H
#define AT_TOK_H 1

int at_tok_start(char **p_cur);
int at_tok_nextint(char **p_cur, int *p_out);
int at_tok_nexthexint(char **p_cur, int *p_out);

int at_tok_nextbool(char **p_cur, char *p_out);
int at_tok_nextstr(char **p_cur, char **out);

int at_tok_hasmore(char **p_cur);

int at_tok_charcounter(char *p_in, char needle, int *p_out);
#endif
   fcp_parser.c                                                                                        0000644 0001750 0001750 00000011632 12271742740 013207  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2010
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
** http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Dmitry Tarnyagin <dmitry.tarnyagin@stericsson.com>
*/

#include <memory.h>
#include <errno.h>
#include <stdio.h>

#define LOG_TAG "RILV"
#include <utils/Log.h>

#include "fcp_parser.h"
#include "misc.h"

int fcp_to_ts_51011(/*in*/ const char *stream, /*in*/ size_t len,
        /*out*/ struct ts_51011_921_resp *out)
{
    const char *end = &stream[len];
    struct tlv fcp;
    int ret = parseTlv(stream, end, &fcp);
    const char *what = NULL;
#define FCP_CVT_THROW(_ret, _what)  \
    do {                    \
        ret = _ret;         \
        what = _what;       \
        goto except;        \
    } while (0)

    if (ret < 0)
        FCP_CVT_THROW(ret, "ETSI TS 102 221, 11.1.1.3: FCP template TLV structure");
    if (fcp.tag != 0x62)
        FCP_CVT_THROW(-EINVAL, "ETSI TS 102 221, 11.1.1.3: FCP template tag");

    /*
     * NOTE: Following fields do not exist in FCP template:
     * - file_acc
     * - file_status
     */

    memset(out, 0, sizeof(*out));
    while (fcp.data < fcp.end) {
        unsigned char fdbyte;
        size_t property_size;
        struct tlv tlv;
        ret = parseTlv(fcp.data, end, &tlv);
        if (ret < 0)
            FCP_CVT_THROW(ret, "ETSI TS 102 221, 11.1.1.3: FCP property TLV structure");
        property_size = (tlv.end - tlv.data) / 2;

        switch (tlv.tag) {
            case 0x80: /* File size, ETSI TS 102 221, 11.1.1.4.1 */
                /* File size > 0xFFFF is not supported by ts_51011 */
                if (property_size != 2)
                    FCP_CVT_THROW(-ENOTSUP, "3GPP TS 51 011, 9.2.1: Unsupported file size");
                /* be16 on both sides */
                ((char*)&out->file_size)[0] = TLV_DATA(tlv, 0);
                ((char*)&out->file_size)[1] = TLV_DATA(tlv, 1);
                break;
            case 0x83: /* File identifier, ETSI TS 102 221, 11.1.1.4.4 */
                /* Sanity check */
                if (property_size != 2)
                    FCP_CVT_THROW(-EINVAL, "ETSI TS 102 221, 11.1.1.4.4: Invalid file identifier");
                /* be16 on both sides */
                ((char*)&out->file_id)[0] = TLV_DATA(tlv, 0);
                ((char*)&out->file_id)[1] = TLV_DATA(tlv, 1);
                break;
            case 0x82: /* File descriptior, ETSI TS 102 221, 11.1.1.4.3 */
                /* Sanity check */
                if (property_size < 2)
                    FCP_CVT_THROW(-EINVAL, "ETSI TS 102 221, 11.1.1.4.3: Invalid file descriptor");
                fdbyte = TLV_DATA(tlv, 0);
                /* ETSI TS 102 221, Table 11.5 for FCP fields */
                /* 3GPP TS 51 011, 9.2.1 and 9.3 for 'out' fields */
                if ((fdbyte & 0xBF) == 0x38) {
                    out->file_type = 2; /* DF of ADF */
                } else if ((fdbyte & 0xB0) == 0x00) {
                    out->file_type = 4; /* EF */
                    out->file_status = 1; /* Not invalidated */
                    ++out->data_size; /* file_structure field is valid */
                    if ((fdbyte & 0x07) == 0x01) {
                        out->file_structure = 0; /* Transparent */
                    } else {
                        if (property_size < 5)
                            FCP_CVT_THROW(-EINVAL, "ETSI TS 102 221, 11.1.1.4.3: Invalid non-transparent file descriptor");
                        ++out->data_size; /* record_size field is valid */
                        out->record_size = TLV_DATA(tlv, 3);
                        if ((fdbyte & 0x07) == 0x06) {
                            out->file_structure = 3; /* Cyclic */
                        } else if ((fdbyte & 0x07) == 0x02) {
                            out->file_structure = 1; /* Linear fixed */
                        } else {
                            FCP_CVT_THROW(-EINVAL, "ETSI TS 102 221, 11.1.1.4.3: Invalid file structure");
                        }
                    }
                } else {
                    out->file_type = 0; /* RFU */
                }
                break;
        }
        fcp.data = tlv.end;
    }

 finally:
    return ret;

 except:
 #undef FCP_CVT_THROW
    ALOGE("%s() FCP to TS 510 11: Specification violation: %s.", __func__, what);
    goto finally;
}
                                                                                                      fcp_parser.h                                                                                        0000644 0001750 0001750 00000002624 12271742740 013215  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2010
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
** http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Dmitry Tarnyagin <dmitry.tarnyagin@stericsson.com>
*/

#ifndef FCP_PARSER_H
#define FCP_PARSER_H

#include <stdint.h>
#include <endian.h>

struct ts_51011_921_resp {
    uint8_t   rfu_1[2];
    uint16_t  file_size; /* be16 */
    uint16_t  file_id;   /* be16 */
    uint8_t   file_type;
    uint8_t   rfu_2;
    uint8_t   file_acc[3];
    uint8_t   file_status;
    uint8_t   data_size;
    uint8_t   file_structure;
    uint8_t   record_size;
} __attribute__((packed));

int fcp_to_ts_51011(/*in*/ const char *stream,
                    /*in*/ size_t len,
                    /*out*/ struct ts_51011_921_resp *out);

#endif
                                                                                                            misc.c                                                                                              0000644 0001750 0001750 00000012473 12271742740 012022  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#include <string.h>
#include <errno.h>

#include "misc.h"

/** Returns 1 if line starts with prefix, 0 if it does not. */
int strStartsWith(const char *line, const char *prefix)
{
    for (; *line != '\0' && *prefix != '\0'; line++, prefix++)
        if (*line != *prefix)
            return 0;

    return *prefix == '\0';
}

/**
  * Very simple function that extract and returns whats between ElementBeginTag
  * and ElementEndTag. 
  *
  * Optional ppszRemainingDocument that can return a pointer to the remaining
  * of the document to be "scanned". This can be used if subsequent
  * scanning/searching is desired.
  *
  * This function is used to extract the parameters from the XML result
  * returned by U3xx during a PDP Context setup, and used to parse the
  * tuples of operators returned from AT+COPS.
  *
  *  const char* document        - Document to be scanned
  *  const char* elementBeginTag - Begin tag to scan for, return whats
  *                                between begin/end tags
  *  const char* elementEndTag   - End tag to scan for, return whats
  *                                between begin/end tags
  *  char** remainingDocumen t   - Can return the a pointer to the remaining
  *                                of pszDocument, this parameter is optional
  *
  *  return char* containing whats between begin/end tags, allocated on the
  *               heap, need to free this. 
  *               return NULL if nothing is found.
  */
char *getFirstElementValue(const char* document,
                                  const char* elementBeginTag,
                                  const char* elementEndTag,
                                  char** remainingDocument)
{
    char* value = NULL;
    char* start = NULL;
    char* end = NULL;

    if (document != NULL && elementBeginTag != NULL && elementEndTag != NULL) {
        start = strstr(document, elementBeginTag);
        if (start != NULL) {
            end = strstr(start, elementEndTag);
            if (end != NULL) {
                int n = strlen(elementBeginTag);
                int m = end - (start + n);
                value = (char*) malloc((m + 1) * sizeof(char));
                strncpy(value, (start + n), m);
                value[m] = (char) 0;

                /* Optional, return a pointer to the remaining document,
                   to be used when document contains many tags with same name. */
                if (remainingDocument != NULL)
                    *remainingDocument = end + strlen(elementEndTag);
            }
        }
    }
    return value;
}

char char2nib(char c)
{
    if (c >= 0x30 && c <= 0x39)
        return c - 0x30;

    if (c >= 0x41 && c <= 0x46)
        return c - 0x41 + 0xA;

    if (c >= 0x61 && c <= 0x66)
        return c - 0x61 + 0xA;

    return 0;
}

int stringToBinary(/*in*/ const char *string,
                   /*in*/ size_t len,
                   /*out*/ unsigned char *binary)
{
    int pos;
    const char *it;
    const char *end = &string[len];

    if (end < string)
        return -EINVAL;

    if (len & 1)
        return -EINVAL;

    for (pos = 0, it = string; it != end; ++pos, it += 2) {
        binary[pos] = char2nib(it[0]) << 4 | char2nib(it[1]);
    }
    return 0;
}

int binaryToString(/*in*/ const unsigned char *binary,
                   /*in*/ size_t len,
                   /*out*/ char *string)
{
    int pos;
    const unsigned char *it;
    const unsigned char *end = &binary[len];
    static const char nibbles[] =
        {'0', '1', '2', '3', '4', '5', '6', '7',
         '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'};

    if (end < binary)
        return -EINVAL;

    for (pos = 0, it = binary; it != end; ++it, pos += 2) {
        string[pos + 0] = nibbles[*it >> 4];
        string[pos + 1] = nibbles[*it & 0x0f];
    }
    string[pos] = 0;
    return 0;
}

int parseTlv(/*in*/ const char *stream,
             /*in*/ const char *end,
             /*out*/ struct tlv *tlv)
{
#define TLV_STREAM_GET(stream, end, p)  \
    do {                                \
        if (stream + 1 >= end)          \
            goto underflow;             \
        p = ((unsigned)char2nib(stream[0]) << 4)  \
          | ((unsigned)char2nib(stream[1]) << 0); \
        stream += 2;                    \
    } while (0)

    size_t size;

    TLV_STREAM_GET(stream, end, tlv->tag);
    TLV_STREAM_GET(stream, end, size);
    if (stream + size * 2 > end)
        goto underflow;
    tlv->data = &stream[0];
    tlv->end  = &stream[size * 2];
    return 0;

underflow:
    return -EINVAL;
#undef TLV_STREAM_GET
}
                                                                                                                                                                                                     misc.h                                                                                              0000644 0001750 0001750 00000003642 12271742740 012025  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#ifndef _U300_RIL_MISC_H
#define _U300_RIL_MISC_H 1

struct tlv {
    unsigned    tag;
    const char *data;
    const char *end;
};

/** Returns 1 if line starts with prefix, 0 if it does not. */
int strStartsWith(const char *line, const char *prefix);

char *getFirstElementValue(const char* document,
                           const char* elementBeginTag,
                           const char* elementEndTag,
                           char** remainingDocument);

char char2nib(char c);

int stringToBinary(/*in*/ const char *string,
                   /*in*/ size_t len,
                   /*out*/ unsigned char *binary);

int binaryToString(/*in*/ const unsigned char *binary,
                   /*in*/ size_t len,
                   /*out*/ char *string);

int parseTlv(/*in*/ const char *stream,
             /*in*/ const char *end,
             /*out*/ struct tlv *tlv);
#define TLV_DATA(tlv, pos) (((unsigned)char2nib(tlv.data[(pos) * 2 + 0]) << 4) | \
                            ((unsigned)char2nib(tlv.data[(pos) * 2 + 1]) << 0))

#define NUM_ELEMS(x) (sizeof(x) / sizeof(x[0]))

#endif
                                                                                              MODULE_LICENSE_APACHE2                                                                              0000644 0001750 0001750 00000000000 12271742740 014037  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                net-utils.c                                                                                         0000644 0001750 0001750 00000012113 12316216031 012767  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /*
 * Copyright 2008, The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); 
 * you may not use this file except in compliance with the License. 
 * You may obtain a copy of the License at 
 *
 *     http://www.apache.org/licenses/LICENSE-2.0 
 *
 * Unless required by applicable law or agreed to in writing, software 
 * distributed under the License is distributed on an "AS IS" BASIS, 
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
 * See the License for the specific language governing permissions and 
 * limitations under the License.
 */

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

#include <sys/socket.h>
#include <sys/select.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <linux/if.h>
#include <linux/sockios.h>
#include <linux/route.h>
#include <linux/wireless.h>

#define LOG_TAG "RIL"
#include <utils/Log.h>
#include <cutils/properties.h>

#define PATH_PROC_NET_DEV               "/proc/net/dev"
#define isspace(c) ((c) == ' ')

static int ifc_ctl_sock = -1;

static const char *ipaddr_to_string(in_addr_t addr)
{
    struct in_addr in_addr;

    in_addr.s_addr = addr;
    return inet_ntoa(in_addr);
}

int ifc_init(void)
{
    if (ifc_ctl_sock == -1) {
        ifc_ctl_sock = socket(AF_INET, SOCK_DGRAM, 0);
        if (ifc_ctl_sock < 0) {
            ALOGE("%s() socket() failed: %s", __func__, strerror(errno));
            ifc_ctl_sock = -1;
        }
    }
    return ifc_ctl_sock < 0 ? -1 : 0;
}

void ifc_close(void)
{
    if (ifc_ctl_sock != -1) {
        (void) close(ifc_ctl_sock);
        ifc_ctl_sock = -1;
    }
}

static void ifc_init_ifr(const char *name, struct ifreq *ifr)
{
    memset(ifr, 0, sizeof(struct ifreq));
    strncpy(ifr->ifr_name, name, IFNAMSIZ);
    ifr->ifr_name[IFNAMSIZ - 1] = 0;
}

static int ifc_set_flags(const char *name, unsigned set, unsigned clr)
{
    struct ifreq ifr;
    ifc_init_ifr(name, &ifr);

    if (ioctl(ifc_ctl_sock, SIOCGIFFLAGS, &ifr) < 0)
        return -1;
    ifr.ifr_flags = (ifr.ifr_flags & (~clr)) | set;
    return ioctl(ifc_ctl_sock, SIOCSIFFLAGS, &ifr);
}

int ifc_up(const char *name)
{
    return ifc_set_flags(name, IFF_UP | IFF_NOARP, 0);
}

int ifc_down(const char *name)
{
    return ifc_set_flags(name, IFF_NOARP, IFF_UP);
}

static void init_sockaddr_in(struct sockaddr *sa, in_addr_t addr)
{
    struct sockaddr_in *sin = (struct sockaddr_in *) sa;
    sin->sin_family = AF_INET;
    sin->sin_port = 0;
    sin->sin_addr.s_addr = addr;
}

int ifc_set_addr(const char *name, in_addr_t addr)
{
    struct ifreq ifr;

    ifc_init_ifr(name, &ifr);
    init_sockaddr_in(&ifr.ifr_addr, addr);

    return ioctl(ifc_ctl_sock, SIOCSIFADDR, &ifr);
}

int ifc_set_mask(const char *name, in_addr_t mask)
{
    struct ifreq ifr;

    ifc_init_ifr(name, &ifr);
    init_sockaddr_in(&ifr.ifr_addr, mask);

    return ioctl(ifc_ctl_sock, SIOCSIFNETMASK, &ifr);
}

int ifc_configure(const char *ifname,
        in_addr_t address,
        in_addr_t gateway)
{
    in_addr_t netmask = ~0;
    (void) gateway;

    ifc_init();

    if (ifc_up(ifname)) {
        ALOGE("%s() Failed to turn on interface %s: %s", __func__,
            ifname,
            strerror(errno));
        ifc_close();
        return -1;
    }
    if (ifc_set_addr(ifname, address)) {
        ALOGE("%s() Failed to set ipaddr %s: %s", __func__,
            ipaddr_to_string(address), strerror(errno));
        ifc_down(ifname);
        ifc_close();
        return -1;
    }
    if (ifc_set_mask(ifname, netmask)) {
        ALOGE("%s() failed to set netmask %s: %s", __func__,
            ipaddr_to_string(netmask), strerror(errno));
        ifc_down(ifname);
        ifc_close();
        return -1;
    }

    ifc_close();

    return 0;
}

static char *get_name(char *name, char *p)
{
	/* Extract <name> from nul-terminated p where p matches
	 * <name>: after leading whitespace.
	 * If match is not made, set name empty and return unchanged p
	 */
	char *nameend;
	char *namestart;
    char *s = p;

	while (*s == ' ' || (unsigned char)(*s - 9) <= (13 - 9))
		s++;

	namestart = s;
	nameend = namestart;
	while (*nameend && *nameend != ':' && !isspace(*nameend))
		nameend++;
	if (*nameend == ':') {
		if ((nameend - namestart) < IFNAMSIZ) {
			memcpy(name, namestart, nameend - namestart);
			name[nameend - namestart] = '\0';
			p = nameend;
		} else {
			/* Interface name too large */
			name[0] = '\0';
		}
	} else {
		/* trailing ':' not found - return empty */
		name[0] = '\0';
	}
	return p + 1;
}

int ifc_statistics(const char *ifname, unsigned long long *rx_packets
                                     , unsigned long long *tx_packets )
{
	FILE *fh;
	char buf[512];

	fh = fopen(PATH_PROC_NET_DEV, "r");
	if (!fh) {
		return -1;
	}

	fgets(buf, sizeof buf, fh);
	fgets(buf, sizeof buf, fh);

	while (fgets(buf, sizeof buf, fh)) {
		char *s, name[128];

		s = get_name(name, buf);
		if (ifname && !strcmp(ifname, name)) {
		sscanf(s, "%*u%llu%*u%*u%*u%*u%*u%*u%*u%llu",
			rx_packets,
			tx_packets);
			fclose(fh);
			return 0;
        }
	}
	fclose(fh);
	return 1;
}
                                                                                                                                                                                                                                                                                                                                                                                                                                                     net-utils.h                                                                                         0000644 0001750 0001750 00000002221 12316216101 012771  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /*
 * Copyright 2008, The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); 
 * you may not use this file except in compliance with the License. 
 * You may obtain a copy of the License at 
 *
 *     http://www.apache.org/licenses/LICENSE-2.0 
 *
 * Unless required by applicable law or agreed to in writing, software 
 * distributed under the License is distributed on an "AS IS" BASIS, 
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
 * See the License for the specific language governing permissions and 
 * limitations under the License.
 */

#ifndef MBM_NET_UTILS_H
#define MBM_NET_UTILS_H 1

int ifc_init(void);
void ifc_close(void);
int ifc_up(const char *name);
int ifc_down(const char *name);
int ifc_set_addr(const char *name, in_addr_t addr);
int ifc_set_mask(const char *name, in_addr_t mask);
int ifc_add_host_route(const char *name);
int ifc_configure(const char *ifname,
        in_addr_t address,
        in_addr_t gateway);
int ifc_statistics(const char *ifname, unsigned long long *rx_packets
                                     , unsigned long long *tx_packets );
#endif
                                                                                                                                                                                                                                                                                                                                                                               NOTICE                                                                                              0000644 0001750 0001750 00000025032 12271742740 011622  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                
   Copyright (c) 2010-2011, Ericsson AB
   Copyright (c) 2008-2009, ST-Ericsson AB
   Copyright (c) 2005-2008, The Android Open Source Project

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.


                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      README                                                                                              0000644 0001750 0001750 00000000334 12271742740 011574  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                
  Ericsson MBM Android Radio Interface Layer

BUILDING

 Apply kernel and initialization script patches:

   # patches/apply_mbm_patches.sh

 Compile the System and RAM Disk Images:

   # cd <path to mydroid>
   # make
                                                                                                                                                                                                                                                                                                    u300-ril.c                                                                                          0000644 0001750 0001750 00000117140 12316215454 012334  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
 *
 * Copyright (C) ST-Ericsson AB 2008-2009
 * Copyright 2006, The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Based on reference-ril by The Android Open Source Project.
 *
 * Heavily modified for ST-Ericsson U300 modems.
 * Author: Christian Bejram <christian.bejram@stericsson.com>
 */

#include <telephony/ril.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <pthread.h>
#include <alloca.h>
#include <getopt.h>
#include <sys/socket.h>
#include <cutils/sockets.h>
#include <termios.h>
#include <stdbool.h>
#include <cutils/properties.h>

#include "atchannel.h"
#include "at_tok.h"
#include "misc.h"

#include "u300-ril.h"
#include "u300-ril-config.h"
#include "u300-ril-messaging.h"
#include "u300-ril-network.h"
#include "u300-ril-pdp.h"
#include "u300-ril-sim.h"
#include "u300-ril-oem.h"
#include "u300-ril-requestdatahandler.h"
#include "u300-ril-error.h"
#include "u300-ril-stk.h"
#include "u300-ril-device.h"

#define LOG_TAG "RIL"
#include <utils/Log.h>

#define RIL_VERSION_STRING "MBM u300-ril 4.0.0.0-beta"

#define MAX_AT_RESPONSE 0x1000

#define MESSAGE_STORAGE_READY_TIMER 3

#define timespec_cmp(a, b, op)         \
        ((a).tv_sec == (b).tv_sec    \
        ? (a).tv_nsec op (b).tv_nsec \
        : (a).tv_sec op (b).tv_sec)

#define TIMEOUT_SEARCH_FOR_TTY 1 /* Poll every Xs for the port*/
#define TIMEOUT_EMRDY 15 /* Module should respond at least within 15s */
#define TIMEOUT_DEVICE_REMOVED 3
#define MAX_BUF 1024

/*** Global Variables ***/
char* ril_iface;
const struct RIL_Env *s_rilenv;

/*** Declarations ***/
static const char *getVersion(void);
static void signalCloseQueues(void);
static void onRequest(int request, void *data, size_t datalen,
                      RIL_Token t);
static int onSupports(int requestCode);
static void onCancel(RIL_Token t);
extern const char *requestToString(int request);

/*** Static Variables ***/
static const RIL_RadioFunctions s_callbacks = {
    RIL_VERSION,
    onRequest,
    getRadioState,
    onSupports,
    onCancel,
    getVersion
};

/*TODO: fix this bad this can dead lock?!?!?*/
static pthread_mutex_t s_screen_state_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_t s_tid_queueRunner;
static pthread_t s_tid_queueRunnerPrio;

static int s_screenState = true;

typedef struct RILRequest {
    int request;
    void *data;
    size_t datalen;
    RIL_Token token;
    struct RILRequest *next;
} RILRequest;

typedef struct RILEvent {
    void (*eventCallback) (void *param);
    void *param;
    char *name;
    struct timespec abstime;
    struct RILEvent *next;
    struct RILEvent *prev;
} RILEvent;

typedef struct RequestQueue {
    pthread_mutex_t queueMutex;
    pthread_cond_t cond;
    RILRequest *requestList;
    RILEvent *eventList;
    char enabled;
    char closed;
} RequestQueue;

static RequestQueue s_requestQueue = {
    .queueMutex = PTHREAD_MUTEX_INITIALIZER,
    .cond = PTHREAD_COND_INITIALIZER,
    .requestList = NULL,
    .eventList = NULL,
    .enabled = 1,
    .closed = 1
};

static RequestQueue s_requestQueuePrio = {
    .queueMutex = PTHREAD_MUTEX_INITIALIZER,
    .cond = PTHREAD_COND_INITIALIZER,
    .requestList = NULL,
    .eventList = NULL,
    .enabled = 0,
    .closed = 1
};

static RequestQueue *s_requestQueues[] = {
    &s_requestQueue,
    &s_requestQueuePrio
};

static const struct timespec TIMEVAL_0 = { 0, 0 };

/**
 * Enqueue a RILEvent to the request queue. isPrio specifies in what queue
 * the request will end up.
 *
 * 0 = the "normal" queue, 1 = prio queue and 2 = both. If only one queue
 * is present, then the event will be inserted into that queue.
 */
void enqueueRILEventName(int isPrio, void (*callback) (void *param),
                     void *param, const struct timespec *relativeTime, char *name)
{
    int err;
    struct timespec ts;
    char done = 0;
    RequestQueue *q = NULL;

    if (NULL == callback) {
        ALOGE("%s() callback is NULL, event not queued!", __func__);
        return;
    }

    RILEvent *e = malloc(sizeof(RILEvent));
    memset(e, 0, sizeof(RILEvent));

    e->eventCallback = callback;
    e->param = param;
    e->name = name;

    if (relativeTime == NULL) {
        relativeTime = alloca(sizeof(struct timeval));
        memset((struct timeval *) relativeTime, 0, sizeof(struct timeval));
    }

    clock_gettime(CLOCK_MONOTONIC, &ts);

    e->abstime.tv_sec = ts.tv_sec + relativeTime->tv_sec;
    e->abstime.tv_nsec = ts.tv_nsec + relativeTime->tv_nsec;

    if (e->abstime.tv_nsec > 1000000000) {
        e->abstime.tv_sec++;
        e->abstime.tv_nsec -= 1000000000;
    }

    if (!s_requestQueuePrio.enabled ||
        (isPrio == RIL_EVENT_QUEUE_NORMAL || isPrio == RIL_EVENT_QUEUE_ALL)) {
        q = &s_requestQueue;
    } else if (isPrio == RIL_EVENT_QUEUE_PRIO)
        q = &s_requestQueuePrio;

again:
    if ((err = pthread_mutex_lock(&q->queueMutex)) != 0)
        ALOGE("%s() failed to take queue mutex: %s!", __func__, strerror(err));

    if (q->eventList == NULL)
        q->eventList = e;
    else {
        if (timespec_cmp(q->eventList->abstime, e->abstime, > )) {
            e->next = q->eventList;
            q->eventList->prev = e;
            q->eventList = e;
        } else {
            RILEvent *tmp = q->eventList;
            do {
                if (timespec_cmp(tmp->abstime, e->abstime, > )) {
                    tmp->prev->next = e;
                    e->prev = tmp->prev;
                    tmp->prev = e;
                    e->next = tmp;
                    break;
                } else if (tmp->next == NULL) {
                    tmp->next = e;
                    e->prev = tmp;
                    break;
                }
                tmp = tmp->next;
            } while (tmp);
        }
    }

    if ((err = pthread_cond_broadcast(&q->cond)) != 0)
        ALOGE("%s() failed to take broadcast queue update: %s!",
            __func__, strerror(err));

    if ((err = pthread_mutex_unlock(&q->queueMutex)) != 0)
        ALOGE("%s() failed to release queue mutex: %s!",
            __func__, strerror(err));

    if (s_requestQueuePrio.enabled && isPrio == RIL_EVENT_QUEUE_ALL && !done) {
        RILEvent *e2 = malloc(sizeof(RILEvent));
        memcpy(e2, e, sizeof(RILEvent));
        e = e2;
        done = 1;
        q = &s_requestQueuePrio;

        goto again;
    }
}

/**
 * Will LOCK THE MUTEX! MAKE SURE TO RELEASE IT!
 */
void getScreenStateLock(void)
{
    int err;

    /* Just make sure we're not changing anything with regards to screen state. */
    if ((err = pthread_mutex_lock(&s_screen_state_mutex)) != 0)
        ALOGE("%s() failed to take screen state mutex: %s",
            __func__,  strerror(err));
}

int getScreenState(void)
{
    return s_screenState;
}

void releaseScreenStateLock(void)
{
    int err;

    if ((err = pthread_mutex_unlock(&s_screen_state_mutex)) != 0)
        ALOGE("%s() failed to release screen state mutex: %s",
            __func__,  strerror(err));

}

void setScreenState(int screenState)
{
    if (screenState == 1) {
        /* Screen is on - be sure to enable all unsolicited notifications again. */
        at_send_command("AT+CREG=2");
        at_send_command("AT+CGREG=2");
        at_send_command("AT+CGEREP=1,0");

        isSimSmsStorageFull(NULL);
        pollSignalStrength((void *)-1);

        at_send_command("AT+CMER=3,0,0,1");

    } else if (screenState == 0) {
        /* Screen is off - disable all unsolicited notifications. */
        at_send_command("AT+CREG=0");
        at_send_command("AT+CGREG=0");
        at_send_command("AT+CGEREP=0,0");
        at_send_command("AT+CMER=3,0,0,0");
    }
}

static void requestScreenState(void *data, size_t datalen, RIL_Token t)
{
    (void) datalen;

    getScreenStateLock();

    if (datalen < sizeof(int *))
        goto error;

    /* No point of enabling unsolicited if radio is off 
       or SIM is locked */
    if (RADIO_STATE_SIM_READY != getRadioState())
        goto success;

    s_screenState = ((int *) data)[0];

    if (s_screenState < 2)
        setScreenState(s_screenState);
    else
        goto error;

success:
    RIL_onRequestComplete(t, RIL_E_SUCCESS, NULL, 0);

finally:
    releaseScreenStateLock();
    return;

error:
    ALOGE("ERROR: requestScreenState failed");
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);

    goto finally;
}

/**
 * RIL_REQUEST_GET_CURRENT_CALLS
 *
 * Requests current call list.
 */
void requestGetCurrentCalls(void *data, size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen;

    /* Respond SUCCESS just to omit repeated requests (see ril.h) */
    RIL_onRequestComplete(t, RIL_E_SUCCESS, NULL, 0);
}

static char isPrioRequest(int request)
{
    unsigned int i;
    for (i = 0; i < sizeof(prioRequests) / sizeof(int); i++)
        if (request == prioRequests[i])
            return 1;
    return 0;
}

static void processRequest(int request, void *data, size_t datalen, RIL_Token t)
{
    ALOGD("%s() %s", __func__, requestToString(request));

    /*
     * These commands won't accept RADIO_NOT_AVAILABLE, so we just return
     * GENERIC_FAILURE if we're not in SIM_STATE_READY.
     */
    RIL_RadioState radio_state = getRadioState();

    if (radio_state != RADIO_STATE_SIM_READY
        && (request == RIL_REQUEST_WRITE_SMS_TO_SIM ||
            request == RIL_REQUEST_DELETE_SMS_ON_SIM)) {
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
        return;
    }

    /* Ignore all requests except RIL_REQUEST_GET_SIM_STATUS
     * when RADIO_STATE_UNAVAILABLE.
     */
    if (radio_state == RADIO_STATE_UNAVAILABLE
        && request != RIL_REQUEST_GET_SIM_STATUS) {
        RIL_onRequestComplete(t, RIL_E_RADIO_NOT_AVAILABLE, NULL, 0);
        return;
    }

    /* Ignore all non-power requests when RADIO_STATE_OFF
     * (except RIL_REQUEST_GET_SIM_STATUS and a few more).
     */
    if ((radio_state == RADIO_STATE_OFF || radio_state == RADIO_STATE_SIM_NOT_READY)
        && !(request == RIL_REQUEST_RADIO_POWER ||
             request == RIL_REQUEST_GET_SIM_STATUS ||
             request == RIL_REQUEST_STK_GET_PROFILE ||
             request == RIL_REQUEST_STK_SET_PROFILE ||
             request == RIL_REQUEST_REPORT_STK_SERVICE_IS_RUNNING ||
             request == RIL_REQUEST_GET_IMEISV ||
             request == RIL_REQUEST_GET_IMEI ||
             request == RIL_REQUEST_BASEBAND_VERSION ||
             request == RIL_REQUEST_SCREEN_STATE)) {
        RIL_onRequestComplete(t, RIL_E_RADIO_NOT_AVAILABLE, NULL, 0);
        return;
    }

    /* Don't allow radio operations when sim is absent or locked! */
    if (radio_state == RADIO_STATE_SIM_LOCKED_OR_ABSENT
        && !(request == RIL_REQUEST_ENTER_SIM_PIN ||
             request == RIL_REQUEST_ENTER_SIM_PUK ||
             request == RIL_REQUEST_ENTER_SIM_PIN2 ||
             request == RIL_REQUEST_ENTER_SIM_PUK2 ||
             request == RIL_REQUEST_ENTER_DEPERSONALIZATION_CODE ||
             request == RIL_REQUEST_GET_SIM_STATUS ||
             request == RIL_REQUEST_RADIO_POWER ||
             request == RIL_REQUEST_GET_IMEISV ||
             request == RIL_REQUEST_GET_IMEI ||
             request == RIL_REQUEST_BASEBAND_VERSION ||
             request == RIL_REQUEST_DATA_REGISTRATION_STATE ||
             request == RIL_REQUEST_VOICE_REGISTRATION_STATE ||
             request == RIL_REQUEST_OPERATOR ||
             request == RIL_REQUEST_QUERY_NETWORK_SELECTION_MODE ||
             request == RIL_REQUEST_SCREEN_STATE ||
             request == RIL_REQUEST_GET_CURRENT_CALLS)) {
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
        return;
    }

    switch (request) {

        case RIL_REQUEST_GET_CURRENT_CALLS:
            if (radio_state == RADIO_STATE_SIM_LOCKED_OR_ABSENT)
                RIL_onRequestComplete(t, RIL_E_RADIO_NOT_AVAILABLE, NULL, 0);
            else
                requestGetCurrentCalls(data, datalen, t);
            break;
        case RIL_REQUEST_SCREEN_STATE:
            requestScreenState(data, datalen, t);
            break;

        /* Data Call Requests */
        case RIL_REQUEST_SETUP_DATA_CALL:
            requestSetupDefaultPDP(data, datalen, t);
            break;
        case RIL_REQUEST_DEACTIVATE_DATA_CALL:
            requestDeactivateDefaultPDP(data, datalen, t);
            break;
        case RIL_REQUEST_LAST_DATA_CALL_FAIL_CAUSE:
            requestLastPDPFailCause(data, datalen, t);
            break;
        case RIL_REQUEST_DATA_CALL_LIST:
            requestPDPContextList(data, datalen, t);
            break;

        /* SMS Requests */
        case RIL_REQUEST_SEND_SMS:
            requestSendSMS(data, datalen, t);
            break;
        case RIL_REQUEST_SEND_SMS_EXPECT_MORE:
            requestSendSMSExpectMore(data, datalen, t);
            break;
        case RIL_REQUEST_WRITE_SMS_TO_SIM:
            requestWriteSmsToSim(data, datalen, t);
            break;
        case RIL_REQUEST_DELETE_SMS_ON_SIM:
            requestDeleteSmsOnSim(data, datalen, t);
            break;
        case RIL_REQUEST_GET_SMSC_ADDRESS:
            requestGetSMSCAddress(data, datalen, t);
            break;
        case RIL_REQUEST_SET_SMSC_ADDRESS:
            requestSetSMSCAddress(data, datalen, t);
            break;
        case RIL_REQUEST_REPORT_SMS_MEMORY_STATUS:
            requestSmsStorageFull(data, datalen, t);
            break;
         case RIL_REQUEST_SMS_ACKNOWLEDGE:
            requestSMSAcknowledge(data, datalen, t);
            break;
        case RIL_REQUEST_GSM_GET_BROADCAST_SMS_CONFIG:
            requestGSMGetBroadcastSMSConfig(data, datalen, t);
            break;
        case RIL_REQUEST_GSM_SET_BROADCAST_SMS_CONFIG:
            requestGSMSetBroadcastSMSConfig(data, datalen, t);
            break;
        case RIL_REQUEST_GSM_SMS_BROADCAST_ACTIVATION:
            requestGSMSMSBroadcastActivation(data, datalen, t);
            break;

        /* SIM Handling Requests */
        case RIL_REQUEST_SIM_IO:
            requestSIM_IO(data, datalen, t);
            break;
        case RIL_REQUEST_GET_SIM_STATUS:
            requestGetSimStatus(data, datalen, t);
            break;
        case RIL_REQUEST_ENTER_SIM_PIN:
        case RIL_REQUEST_ENTER_SIM_PUK:
        case RIL_REQUEST_ENTER_SIM_PIN2:
        case RIL_REQUEST_ENTER_SIM_PUK2:
            requestEnterSimPin(data, datalen, t, request);
            break;
        case RIL_REQUEST_CHANGE_SIM_PIN:
            requestChangePassword(data, datalen, t, "SC", request);
            break;
        case RIL_REQUEST_CHANGE_SIM_PIN2:
            requestChangePassword(data, datalen, t, "P2", request);
            break;
        case RIL_REQUEST_QUERY_FACILITY_LOCK:
            requestQueryFacilityLock(data, datalen, t);
            break;
        case RIL_REQUEST_SET_FACILITY_LOCK:
            requestSetFacilityLock(data, datalen, t);
            break;

        /* Network Requests */
        case RIL_REQUEST_ENTER_DEPERSONALIZATION_CODE:
            requestEnterSimPin(data, datalen, t, request);
            break;
        case RIL_REQUEST_QUERY_NETWORK_SELECTION_MODE:
            requestQueryNetworkSelectionMode(data, datalen, t);
            break;
        case RIL_REQUEST_SET_NETWORK_SELECTION_AUTOMATIC:
            requestSetNetworkSelectionAutomatic(data, datalen, t);
            break;
        case RIL_REQUEST_SET_NETWORK_SELECTION_MANUAL:
            requestSetNetworkSelectionManual(data, datalen, t);
            break;
        case RIL_REQUEST_QUERY_AVAILABLE_NETWORKS:
            requestQueryAvailableNetworks(data, datalen, t);
            break;
        case RIL_REQUEST_SET_PREFERRED_NETWORK_TYPE:
            requestSetPreferredNetworkType(data, datalen, t);
            break;
        case RIL_REQUEST_GET_PREFERRED_NETWORK_TYPE:
            requestGetPreferredNetworkType(data, datalen, t);
            break;
        case RIL_REQUEST_VOICE_REGISTRATION_STATE:
            requestRegistrationState(request, data, datalen, t);
            break;
        case RIL_REQUEST_DATA_REGISTRATION_STATE:
            requestGprsRegistrationState(request, data, datalen, t);
            break;
        case RIL_REQUEST_GET_NEIGHBORING_CELL_IDS:
            requestNeighboringCellIDs(data, datalen, t);
            break;

        /* OEM */
        /* case RIL_REQUEST_OEM_HOOK_RAW:
            requestOEMHookRaw(data, datalen, t);
            break; */
        case RIL_REQUEST_OEM_HOOK_STRINGS:
            requestOEMHookStrings(data, datalen, t);
            break;

        /* Misc */
        case RIL_REQUEST_SIGNAL_STRENGTH:
            requestSignalStrength(data, datalen, t);
            break;
        case RIL_REQUEST_OPERATOR:
            requestOperator(data, datalen, t);
            break;
        case RIL_REQUEST_RADIO_POWER:
            requestRadioPower(data, datalen, t);
            break;
        case RIL_REQUEST_GET_IMSI:
            requestGetIMSI(data, datalen, t);
            break;
        case RIL_REQUEST_GET_IMEI:                  /* Deprecated */
            requestGetIMEI(data, datalen, t);
            break;
        case RIL_REQUEST_GET_IMEISV:                /* Deprecated */
            requestGetIMEISV(data, datalen, t);
            break;
        case RIL_REQUEST_DEVICE_IDENTITY:
            requestDeviceIdentity(data, datalen, t);
            break;
        case RIL_REQUEST_BASEBAND_VERSION:
            requestBasebandVersion(data, datalen, t);
            break;

        /* SIM Application Toolkit */
        case RIL_REQUEST_STK_SEND_TERMINAL_RESPONSE:
            requestStkSendTerminalResponse(data, datalen, t);
            break;
        case RIL_REQUEST_STK_SEND_ENVELOPE_COMMAND:
            requestStkSendEnvelopeCommand(data, datalen, t);
            break;
        case RIL_REQUEST_STK_GET_PROFILE:
            requestStkGetProfile(data, datalen, t);
            break;
        case RIL_REQUEST_STK_SET_PROFILE:
            requestStkSetProfile(data, datalen, t);
            break;
        case RIL_REQUEST_REPORT_STK_SERVICE_IS_RUNNING:
            requestReportStkServiceIsRunning(data, datalen, t);
            getCachedStkMenu();
            break;

        default:
            ALOGW("FIXME: Unsupported request logged: %s",
                 requestToString(request));
            RIL_onRequestComplete(t, RIL_E_REQUEST_NOT_SUPPORTED, NULL, 0);
            break;
    }
}

/*** Callback methods from the RIL library to us ***/

/**
 * Call from RIL to us to make a RIL_REQUEST.
 *
 * Must be completed with a call to RIL_onRequestComplete().
 */
static void onRequest(int request, void *data, size_t datalen, RIL_Token t)
{
    RILRequest *r;
    RequestQueue *q = &s_requestQueue;
    int err;

    if (s_requestQueuePrio.enabled && isPrioRequest(request))
        q = &s_requestQueuePrio;

    r = malloc(sizeof(RILRequest));
    memset(r, 0, sizeof(RILRequest));

    /* Formulate a RILRequest and put it in the queue. */
    r->request = request;
    r->data = dupRequestData(request, data, datalen);
    r->datalen = datalen;
    r->token = t;

    if ((err = pthread_mutex_lock(&q->queueMutex)) != 0)
        ALOGE("%s() failed to take queue mutex: %s!", __func__, strerror(err));

    /* Queue empty, just throw r on top. */
    if (q->requestList == NULL)
        q->requestList = r;
    else {
        RILRequest *l = q->requestList;
        while (l->next != NULL)
            l = l->next;

        l->next = r;
    }

    if ((err = pthread_cond_broadcast(&q->cond)) != 0)
        ALOGE("%s() failed to broadcast queue update: %s!",
            __func__, strerror(err));

    if ((err = pthread_mutex_unlock(&q->queueMutex)) != 0)
        ALOGE("%s() failed to release queue mutex: %s!",
            __func__, strerror(err));
}



/**
 * Call from RIL to us to find out whether a specific request code
 * is supported by this implementation.
 *
 * Return 1 for "supported" and 0 for "unsupported".
 *
 * Currently just stubbed with the default value of one. This is currently
 * not used by android, and therefore not implemented here. We return
 * RIL_E_REQUEST_NOT_SUPPORTED when we encounter unsupported requests.
 */
static int onSupports(int requestCode)
{
    (void) requestCode;
    ALOGI("onSupports() called!");

    return 1;
}

/**
 * onCancel() is currently stubbed, because android doesn't use it and
 * our implementation will depend on how a cancellation is handled in
 * the upper layers.
 */
static void onCancel(RIL_Token t)
{
    (void) t;
    ALOGI("onCancel() called!");
}

static const char *getVersion(void)
{
    return RIL_VERSION_STRING;
}

static char initializeCommon(void)
{
    int err = 0;

    set_pending_hotswap(0);
    setE2napState(E2NAP_STATE_UNKNOWN);
    setE2napCause(E2NAP_CAUSE_UNKNOWN);

    if (at_handshake() < 0) {
        LOG_FATAL("Handshake failed!");
        return 1;
    }

    /* Configure/set
     *   command echo (E), result code suppression (Q), DCE response format (V)
     *
     *  E0 = DCE does not echo characters during command state and online
     *       command state
     *  V1 = Display verbose result codes
     */
    err = at_send_command("ATE0V1");
    if (err != AT_NOERROR)
        return 1;

   /* Set default character set. */
    err = at_send_command("AT+CSCS=\"UTF-8\"");
    if (err != AT_NOERROR)
        return 1;

    /* Read out device information. Needs to be done prior to enabling
     * unsolicited responses.
     */
    readDeviceInfo();

    /* Enable +CME ERROR: <err> result code and use numeric <err> values. */
    err = at_send_command("AT+CMEE=1");
    if (err != AT_NOERROR)
        return 1;

    err = at_send_command("AT*E2NAP=1");
    /* TODO: this command may return CME error */
    if (err != AT_NOERROR)
        return 1;

    /* Send the current time of the OS to the module */
    sendTime(NULL);

    /* Try to register for hotswap events. Don't care if it fails. */
    err = at_send_command("AT*EESIMSWAP=1");

    /* Try to register for network capability events. Don't care if it fails. */
    err = at_send_command("AT*ERINFO=1");

    /* Disable Service Reporting. */
    err = at_send_command("AT+CR=0");
    if (err != AT_NOERROR)
        return 1;

    /* Configure carrier detect signal - 1 = DCD follows the connection. */
    err = at_send_command("AT&C=1");
    if (err != AT_NOERROR)
        return 1;

    /* Configure DCE response to Data Termnal Ready signal - 0 = ignore. */
    err = at_send_command("AT&D=0");
    if (err != AT_NOERROR)
        return 1;

    /* Configure Bearer Service Type and HSCSD Non-Transparent Call
     *  +CBST
     *     7 = 9600 bps V.32
     *     0 = Asynchronous connection
     *     1 = Non-transparent connection element
     */
    err = at_send_command("AT+CBST=7,0,1");
    if (err != AT_NOERROR)
        return 1;

    /* restore state of STK */
    if (get_stk_service_running()) {
        init_stk_service();
        getCachedStkMenu();
    }

    return 0;
}

/**
 * Initialize everything that can be configured while we're still in
 * AT+CFUN=0.
 */
static char initializeChannel(void)
{
    int err;

    ALOGD("%s()", __func__);

    ResetHotswap();
    setRadioState(RADIO_STATE_OFF);

    /*
     * SIM Application Toolkit Configuration
     *  n = 0 - Disable SAT unsolicited result codes
     *  stkPrfl = - SIM application toolkit profile in hexadecimal format
     *              starting with first byte of the profile.
     *              See 3GPP TS 11.14[1] for details.
     *
     * Terminal profile is currently empty because stkPrfl is currently
     * overriden by the default profile stored in the modem.
     */

    /* Configure Packet Domain Network Registration Status events
     *    2 = Enable network registration and location information
     *        unsolicited result code
     */
    err = at_send_command("AT+CGREG=2");
    if (err != AT_NOERROR)
        return 1;

    /* Set phone functionality.
     *    4 = Disable the phone's transmit and receive RF circuits.
     */
    err = at_send_command("AT+CFUN=4");
    if (err != AT_NOERROR)
        return 1;

    /* Assume radio is off on error. */
    if (isRadioOn() > 0)
        setRadioState(RADIO_STATE_SIM_NOT_READY);

    return 0;
}

/**
 * Initialize everything that can be configured while we're still in
 * AT+CFUN=0.
 */
static char initializePrioChannel(void)
{
    int err;

    ALOGD("%s()", __func__);

    /* Subscribe to Pin code event.
     *   The command requests the MS to report when the PIN code has been
     *   inserted and accepted.
     *      1 = Request for report on inserted PIN code is activated (on)
     */
    err = at_send_command("AT*EPEE=1");
    if (err != AT_NOERROR)
        return 1;

    return 0;
}

/**
 * Called by atchannel when an unsolicited line appears.
 * This is called on atchannel's reader thread. AT commands may
 * not be issued here.
 */
static void onUnsolicited(const char *s, const char *sms_pdu)
{
    /* Ignore unsolicited responses until we're initialized.
       This is OK because the RIL library will poll for initial state. */
    if (getRadioState() == RADIO_STATE_UNAVAILABLE)
        return;

    if (strStartsWith(s, "*ETZV:")) {
        onNetworkTimeReceived(s);
    } else if ((strStartsWith(s, "*EPEV")) || (strStartsWith(s, "+CGEV:"))) {
        /* Pin event, poll SIM State! */
        enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, pollSIMState, (void*) 1, NULL);
    } else if (strStartsWith(s, "*ESIMSR"))
        onSimStateChanged(s);
    else if(strStartsWith(s, "*E2NAP:")) {
        enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, pollSIMState, (void*) 1, NULL);
        onConnectionStateChanged(s);
    } else if(strStartsWith(s, "*ERINFO:"))
        onNetworkCapabilityChanged(s);
    else if(strStartsWith(s, "*E2REG:"))
        onNetworkStatusChanged(s);
    else if (strStartsWith(s, "*EESIMSWAP:"))
        onSimHotswap(s);
    else if (strStartsWith(s, "+CREG:")
            || strStartsWith(s, "+CGREG:"))
        onRegistrationStatusChanged(s);
    else if (strStartsWith(s, "+CMT:"))
        onNewSms(sms_pdu);
    else if (strStartsWith(s, "+CBM:"))
        onNewBroadcastSms(sms_pdu);
    else if (strStartsWith(s, "+CMTI:"))
        onNewSmsOnSIM(s);
    else if (strStartsWith(s, "+CDS:"))
        onNewStatusReport(sms_pdu);
    else if (strStartsWith(s, "+CIEV: 2"))
        onSignalStrengthChanged(s);
    else if (strStartsWith(s, "+CIEV: 7"))
        onNewSmsIndication();
    else if (strStartsWith(s, "*STKEND"))
        RIL_onUnsolicitedResponse(RIL_UNSOL_STK_SESSION_END, NULL, 0);
    else if (strStartsWith(s, "*STKI:"))
        onStkProactiveCommand(s);
    else if (strStartsWith(s, "*STKN:"))
        onStkEventNotify(s);
    else if (strStartsWith(s, "+PACSP0")) { 
        setRadioState(RADIO_STATE_SIM_READY); 
    } 
}

static void signalCloseQueues(void)
{
    unsigned int i;
    for (i = 0; i < (sizeof(s_requestQueues) / sizeof(RequestQueue *)); i++) {
        int err;
        RequestQueue *q = s_requestQueues[i];
        if ((err = pthread_mutex_lock(&q->queueMutex)) != 0)
            ALOGE("%s() failed to take queue mutex: %s",
                __func__, strerror(err));

        q->closed = 1;
        if ((err = pthread_cond_signal(&q->cond)) != 0)
            ALOGE("%s() failed to broadcast queue update: %s",
                __func__, strerror(err));

        if ((err = pthread_mutex_unlock(&q->queueMutex)) != 0)
            ALOGE("%s() failed to take queue mutex: %s", __func__,
                 strerror(err));
    }
}

/* Called on command or reader thread. */
static void onATReaderClosed(void)
{
    ALOGD("%s() Calling at_close()", __func__);

    at_close();

    if (!get_pending_hotswap())
        setRadioState(RADIO_STATE_UNAVAILABLE);
    signalCloseQueues();

}

/* Called on command thread. */
static void onATTimeout(void)
{
    static int strike = 0;

    strike++;

    ALOGD("%s() AT channel timeout", __func__);

     /* Last resort, throw escape on the line, close the channel
        and hope for the best. */

    at_send_escape();
    at_close();

    setRadioState(RADIO_STATE_UNAVAILABLE);
    signalCloseQueues();

    /* Eperimental reboot of module on NotionInk Adam 3G tablet */
    if (strike == 2) {
        strike = 0;
        ALOGW("*** Cold booting module ***");
        system("echo 0 > /sys/bus/platform/devices/smba-pm-gsm/power_on");
        sleep(1);
        system("echo 1 > /sys/bus/platform/devices/smba-pm-gsm/power_on");
    }
}

static void usage(char *s)
{
    fprintf(stderr, "usage: %s [-z] [-p <tcp port>] [-d /dev/tty_device] [-x /dev/tty_device] [-i <network interface>]\n", s);
    exit(-1);
}

struct queueArgs {
    int port;
    char * loophost;
    const char *device_path;
    char isPrio;
    char hasPrio;
};

static int safe_read(int fd, char *buf, int count)
{
    int n;
    int i = 0;

    while (i < count) {
        n = read(fd, buf + i, count - i);
        if (n > 0)
            i += n;
        else if (!(n < 0 && errno == EINTR))
            return -1;
    }

    return count;
}

static void *queueRunner(void *param)
{
    int fd = -1;
    int ret = 0;
    int n;
    fd_set input;
    struct timeval timeout;
    int max_fd = -1;
    char start[MAX_BUF];
    struct queueArgs *queueArgs = (struct queueArgs *) param;
    struct RequestQueue *q = NULL;
    struct stat sb;

    ALOGI("%s() starting!", __func__);

    for (;;) {
        fd = -1;
        max_fd = -1;
        n = 0;
        while (fd < 0) {
            if (queueArgs->port > 0) {
                if (queueArgs->loophost)
                    fd = socket_network_client(queueArgs->loophost, queueArgs->port, SOCK_STREAM);
                else
                    fd = socket_loopback_client(queueArgs->port, SOCK_STREAM);
            } else if (queueArgs->device_path != NULL) {
                /* Program is not controlling terminal -> O_NOCTTY */
                /* Dont care about DCD -> O_NDELAY */
                fd = open(queueArgs->device_path, O_RDWR | O_NOCTTY); /* | O_NDELAY); */
                if (fd >= 0 && !memcmp(queueArgs->device_path, "/dev/ttyA", 9)) {
                    struct termios ios;
                    /* Clear the struct and then call cfmakeraw*/
                    tcflush(fd, TCIOFLUSH);
                    tcgetattr(fd, &ios);
                    memset(&ios, 0, sizeof(struct termios));
                    cfmakeraw(&ios);
                    /* OK now we are in a known state, set what we want*/
                    ios.c_cflag |= CRTSCTS;
                    /* ios.c_cc[VMIN]  = 0; */
                    /* ios.c_cc[VTIME] = 1; */
                    ios.c_cflag |= CS8;
                    tcsetattr(fd, TCSANOW, &ios);
                    tcflush(fd, TCIOFLUSH);
                    tcsetattr(fd, TCSANOW, &ios);
                    tcflush(fd, TCIOFLUSH);
                    tcflush(fd, TCIOFLUSH);
                    cfsetospeed(&ios, B115200);
                    cfsetispeed(&ios, B115200);
                    tcsetattr(fd, TCSANOW, &ios);

                }
            }

            if (fd < 0) {
                if (n == 0) {
                    ALOGE("%s() Failed to open AT channel %s (%s), will silently retry every %ds",
                        __func__, queueArgs->device_path, strerror(errno), TIMEOUT_SEARCH_FOR_TTY);
                    n = 1;
                }
                sleep(TIMEOUT_SEARCH_FOR_TTY);
            }
        }

        /* Reset the blocking mode*/
        fcntl(fd, F_SETFL, 0);
        FD_ZERO(&input);
        FD_SET(fd, &input);
        if (fd >= max_fd)
            max_fd = fd + 1;

        timeout.tv_sec = TIMEOUT_EMRDY;
        timeout.tv_usec = 0;

        ALOGD("%s() Waiting for EMRDY...", __func__);
        n = select(max_fd, &input, NULL, NULL, &timeout);

        if (n < 0) {
            ALOGE("%s() Select error", __func__);
            return NULL;
        } else if (n == 0)
            ALOGE("%s() timeout, go ahead anyway(might work)...", __func__);
        else {
            memset(start, 0, MAX_BUF);
            safe_read(fd, start, MAX_BUF-1);

            if (start == NULL) {
                ALOGD("%s() Oops, empty string", __func__);
                tcflush(fd, TCIOFLUSH);
                FD_CLR(fd, &input);
                close(fd);
                continue;
            }

            if (strstr(start, "EMRDY") == NULL) {
                ALOGD("%s() Oops, this was not EMRDY: %s", __func__, start);
                tcflush(fd, TCIOFLUSH);
                FD_CLR(fd, &input);
                close(fd);
                continue;
            }

            ALOGD("%s() Got EMRDY", __func__);
        }

        ret = at_open(fd, onUnsolicited);

        if (ret < 0) {
            ALOGE("%s() AT error %d on at_open", __func__, ret);
            at_close();
            continue;
        }

        at_set_on_reader_closed(onATReaderClosed);
        at_set_on_timeout(onATTimeout);
        at_set_timeout_msec(1000 * 30);

        q = &s_requestQueue;

        if(initializeCommon()) {
            ALOGE("%s() Failed to initialize channel!", __func__);
            at_close();
            continue;
        }

        if (queueArgs->isPrio == 0) {
            q->closed = 0;
            if (initializeChannel()) {
                ALOGE("%s() Failed to initialize channel!", __func__);
                at_close();
                continue;
            }
            at_make_default_channel();
        } else {
            q = &s_requestQueuePrio;
            q->closed = 0;
            at_set_timeout_msec(1000 * 30);
        }

        if (queueArgs->hasPrio == 0 || queueArgs->isPrio)
            if (initializePrioChannel()) {
                ALOGE("%s() Failed to initialize channel!", __func__);
                at_close();
                continue;
            }

        ALOGE("%s() Looping the requestQueue!", __func__);
        for (;;) {
            RILRequest *r;
            RILEvent *e;
            struct timespec ts;
            int err;

            memset(&ts, 0, sizeof(ts));

            if ((err = pthread_mutex_lock(&q->queueMutex)) != 0)
                ALOGE("%s() failed to take queue mutex: %s!",
                    __func__, strerror(err));

            if (q->closed != 0) {
                ALOGW("%s() AT Channel error, attempting to recover..", __func__);
                if ((err = pthread_mutex_unlock(&q->queueMutex)) != 0)
                    ALOGE("Failed to release queue mutex: %s!", strerror(err));
                break;
            }

            while (q->closed == 0 && q->requestList == NULL &&
                q->eventList == NULL) {
                if ((err = pthread_cond_wait(&q->cond, &q->queueMutex)) != 0)
                    ALOGE("%s() failed broadcast queue cond: %s!",
                        __func__, strerror(err));
            }

            /* eventList is prioritized, smallest abstime first. */
            if (q->closed == 0 && q->requestList == NULL && q->eventList) {
                int err = 0;
                err = pthread_cond_timedwait_monotonic_np(&q->cond, &q->queueMutex, &q->eventList->abstime);
                if (err && err != ETIMEDOUT)
                    ALOGE("%s() timedwait returned unexpected error: %s",
		        __func__, strerror(err));
            }

            if (q->closed != 0) {
                if ((err = pthread_mutex_unlock(&q->queueMutex)) != 0)
                    ALOGE("%s(): Failed to release queue mutex: %s!",
                        __func__, strerror(err));
                continue; /* Catch the closed bit at the top of the loop. */
            }

            e = NULL;
            r = NULL;

            clock_gettime(CLOCK_MONOTONIC, &ts);

            if (q->eventList != NULL &&
                timespec_cmp(q->eventList->abstime, ts, < )) {
                e = q->eventList;
                q->eventList = e->next;
            }

            if (q->requestList != NULL) {
                r = q->requestList;
                q->requestList = r->next;
            }

            if ((err = pthread_mutex_unlock(&q->queueMutex)) != 0)
                ALOGE("%s(): Failed to release queue mutex: %s!",
                    __func__, strerror(err));

            if (e) {
                if (NULL != e->name)
                    ALOGD("processEvent(%s)",e->name);
                e->eventCallback(e->param);
                free(e);
            }

            if (r) {
                processRequest(r->request, r->data, r->datalen, r->token);
                freeRequestData(r->request, r->data, r->datalen);
                free(r);
            }
        }

        at_close();

        /* Make sure device is removed before trying to reopen
           otherwise we might end up in a race condition when
           device is being removed from filesystem */

        int i = TIMEOUT_DEVICE_REMOVED;
        sleep(1);
        while((i--) && (stat(queueArgs->device_path, &sb) == 0)) {
            ALOGD("%s() Waiting for %s to be removed (%d)...", __func__,
                queueArgs->device_path, i);
            sleep(1);
        }

        ALOGE("%s() Re-opening after close", __func__);
    }
    return NULL;
}

const RIL_RadioFunctions *RIL_Init(const struct RIL_Env *env, int argc,
                                   char **argv)
{
    int opt;
    int port = -1;
    char *loophost = NULL;
    const char *device_path = NULL;
    const char *priodevice_path = NULL;
    struct queueArgs *queueArgs;
    struct queueArgs *prioQueueArgs;
    pthread_attr_t attr;

    s_rilenv = env;

    ALOGD("%s() entering...", __func__);

    while (-1 != (opt = getopt(argc, argv, "z:i:p:d:s:x:"))) {
        switch (opt) {
            case 'z':
                loophost = optarg;
                ALOGD("%s() Using loopback host %s..", __func__, loophost);
                break;

            case 'i':
                ril_iface = optarg;
                ALOGD("%s() Using network interface %s as primary data channel.",
                     __func__, ril_iface);
                break;

            case 'p':
                port = atoi(optarg);
                if (port == 0) {
                    usage(argv[0]);
                    return NULL;
                }
                ALOGD("%s() Opening loopback port %d", __func__, port);
                break;

            case 'd':
                device_path = optarg;
                ALOGD("%s() Opening tty device %s", __func__, device_path);
                break;

            case 'x':
                priodevice_path = optarg;
                ALOGD("%s() Opening priority tty device %s", __func__, priodevice_path);
                break;
            default:
                usage(argv[0]);
                return NULL;
        }
    }

    if (ril_iface == NULL) {
        ALOGD("%s() Network interface was not supplied, falling back on usb0!", __func__);
        ril_iface = strdup("usb0\0");
    }

    if (port < 0 && device_path == NULL) {
        usage(argv[0]);
        return NULL;
    }

    queueArgs = malloc(sizeof(struct queueArgs));
    memset(queueArgs, 0, sizeof(struct queueArgs));

    queueArgs->device_path = device_path;
    queueArgs->port = port;
    queueArgs->loophost = loophost;

    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);

    if (priodevice_path != NULL) {
        prioQueueArgs = malloc(sizeof(struct queueArgs));
        memset(prioQueueArgs, 0, sizeof(struct queueArgs));
        prioQueueArgs->device_path = priodevice_path;
        prioQueueArgs->isPrio = 1;
        prioQueueArgs->hasPrio = 1;
        queueArgs->hasPrio = 1;

        s_requestQueuePrio.enabled = 1;

        pthread_create(&s_tid_queueRunnerPrio, &attr, queueRunner, prioQueueArgs);
    }

    pthread_create(&s_tid_queueRunner, &attr, queueRunner, queueArgs);

    return &s_callbacks;
}
                                                                                                                                                                                                                                                                                                                                                                                                                                u300-ril-config.h                                                                                   0000644 0001750 0001750 00000002440 12271742740 013603  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
** Author: Henrik Persson <henrik.persson@stericsson.com>
*/

#ifndef _U300_RIL_CONFIG_H
#define _U300_RIL_CONFIG_H 1

#include <telephony/ril.h>

/*
 * Requests that will go on the priority queue instead of the normal queue.
 * 
 * If only one queue is configured, the request will be put on the normal
 * queue and sent as a normal request.
 */
static int prioRequests[] = {
    RIL_REQUEST_GET_CURRENT_CALLS,
    RIL_REQUEST_SIGNAL_STRENGTH
};
#endif

                                                                                                                                                                                                                                u300-ril-device.c                                                                                   0000644 0001750 0001750 00000041437 12316214353 013573  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) Ericsson AB 2011
** Copyright (C) ST-Ericsson AB 2008-2010
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
*/

#include <telephony/ril.h>
#include "atchannel.h"
#include "at_tok.h"
#include "misc.h"

#include "u300-ril-device.h"
#include "u300-ril-messaging.h"
#include "u300-ril-sim.h"
#include "u300-ril-network.h"
#include "u300-ril.h"

#define LOG_TAG "RIL"
#include <utils/Log.h>
#include <cutils/properties.h>

#define RADIO_POWER_ATTEMPTS 10
static RIL_RadioState sState = RADIO_STATE_UNAVAILABLE;
static pthread_mutex_t s_state_mutex = PTHREAD_MUTEX_INITIALIZER;
static char** s_deviceInfo = NULL;
static pthread_mutex_t s_deviceInfo_mutex = PTHREAD_MUTEX_INITIALIZER;

char *getTime(void)
{
    ATResponse *atresponse = NULL;
    int err;
    char *line;
    char *currtime = NULL;
    char *resp = NULL;

    err = at_send_command_singleline("AT+CCLK?", "+CCLK:", &atresponse);

    if (err != AT_NOERROR)
        goto error;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    /* Read current time */
    err = at_tok_nextstr(&line, &currtime);
    if (err < 0)
        goto error;

    /* Skip the first two digits of year */
    resp = strdup(currtime+2);

finally:
    at_response_free(atresponse);
    return resp;

error:
    ALOGE("%s() Failed to read current time", __func__);
    goto finally;
}

void sendTime(void *p)
{
    time_t t;
    struct tm tm;
    char *timestr;
    char *currtime;
    char str[20];
    char tz[6];
    int num[4];
    int tzi;
    int i;
    (void) p;

    tzset();
    t = time(NULL);

    if (!(localtime_r(&t, &tm)))
        return;
    if (!(strftime(tz, 12, "%z", &tm)))
        return;

    for (i = 0; i < 4; i++)
        num[i] = tz[i+1] - '0';

    /* convert timezone hours to timezone quarters of hours */
    tzi = (num[0] * 10 + num[1]) * 4 + (num[2] * 10 + num[3]) / 15;
    strftime(str, 20, "%y/%m/%d,%T", &tm);
    asprintf(&timestr, "%s%c%02d", str, tz[0], tzi);

    /* Read time first to make sure an update is necessary */
    currtime = getTime();
    if (NULL == currtime)
        return;

    if (NULL == strstr(currtime, timestr))
        at_send_command("AT+CCLK=\"%s\"", timestr);
    else
        ALOGW("%s() Skipping setting same time again!", __func__);

    free(timestr);
    free(currtime);
    return;
}

void clearDeviceInfo(void)
{
    int i = 0;
    int err;

    if ((err = pthread_mutex_lock(&s_deviceInfo_mutex)) != 0)
        ALOGE("%s() failed to take device info mutex: %s!", __func__, strerror(err));
    else {
        if (s_deviceInfo != NULL) {
            /* s_deviceInfo list shall end with NULL */
            while (s_deviceInfo[i] != NULL) {
                free(s_deviceInfo[i]);
                i++;
            }
            free(s_deviceInfo);
        }

        if ((err = pthread_mutex_unlock(&s_deviceInfo_mutex)) != 0)
            ALOGE("%s() failed to release device info mutex: %s!", __func__, strerror(err));
    }
}

/* Needs to be called while unsolicited responses are not yet enabled, because
 * response prefix in at_send_command_multiline calls is "\0".
 */
void readDeviceInfo(void)
{
    ATResponse *atresponse = NULL;
    ATLine *line;
    int linecnt = 0;
    int err;

    clearDeviceInfo();

    err = at_send_command_multiline("AT*EEVINFO", "\0", &atresponse);
    if (err != AT_NOERROR) {
        /* Older device types might implement AT*EVERS instead of *EEVINFO */
        err = at_send_command_multiline("AT*EVERS", "\0", &atresponse);
        if (err != AT_NOERROR)
            return;
    }

    /* First just count intermediate responses */
    linecnt = 0;
    line = atresponse->p_intermediates;
    while (line) {
        linecnt++;
        line = line->p_next;
    }

    if ((err = pthread_mutex_lock(&s_deviceInfo_mutex)) != 0)
        ALOGE("%s() failed to take device info mutex: %s!", __func__, strerror(err));
    else {
        if (linecnt > 0) {
            s_deviceInfo = calloc(linecnt + 1, sizeof(char *));

            if (s_deviceInfo) {
                /* Now read and store the intermediate responses */
                linecnt = 0;
                line = atresponse->p_intermediates;
                while (line) {
                    s_deviceInfo[linecnt] = strdup(line->line);
                    if (s_deviceInfo[linecnt])
                        linecnt++;
                    else
                        ALOGW("%s() failed to allocate memory", __func__);

                    line = line->p_next;
                }
                /* Mark end of list with NULL */
                s_deviceInfo[linecnt] = NULL;
            }
            else
                ALOGW("%s() failed to allocate memory", __func__);
        }

        if ((err = pthread_mutex_unlock(&s_deviceInfo_mutex)) != 0)
            ALOGE("%s() failed to release device info mutex: %s!", __func__, strerror(err));
    }
    at_response_free(atresponse);
}

char *getDeviceInfo(const char *info)
{
    int i = 0;
    int err;
    char* resp = NULL;

    if ((err = pthread_mutex_lock(&s_deviceInfo_mutex)) != 0)
        ALOGE("%s() failed to take device info mutex: %s!", __func__, strerror(err));
    else {
        if (s_deviceInfo != NULL) {
            /* s_deviceInfo list always ends with a NULL */
            while (s_deviceInfo[i] != NULL) {
                if (strStartsWith(s_deviceInfo[i], info)) {
                    resp = calloc(strlen(s_deviceInfo[i]), sizeof(char));
                    sscanf(s_deviceInfo[i]+strlen(info), "%*s %s", resp);
                    break;
                }
                i++;
            }
        }
        if ((err = pthread_mutex_unlock(&s_deviceInfo_mutex)) != 0)
            ALOGE("%s() failed to release device info mutex: %s!", __func__, strerror(err));
    }

    if (resp == NULL)
        ALOGW("%s() didn't find information for %s", __func__, info);

    return resp;
}

/**
 * RIL_REQUEST_GET_IMSI
*/
void requestGetIMSI(void *data, size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen;
    ATResponse *atresponse = NULL;
    int err;

    err = at_send_command_numeric("AT+CIMI", &atresponse);

    if (err != AT_NOERROR)
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    else {
        RIL_onRequestComplete(t, RIL_E_SUCCESS,
                              atresponse->p_intermediates->line,
                              sizeof(char *));
        at_response_free(atresponse);
    }
}

/* RIL_REQUEST_DEVICE_IDENTITY
 *
 * Request the device ESN / MEID / IMEI / IMEISV.
 *
 */
void requestDeviceIdentity(void *data, size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen;
    char* response[4];

    response[0] = getDeviceInfo("IMEI Data"); /* IMEI */
    response[1] = getDeviceInfo("SVN"); /* IMEISV */

    /* CDMA not supported */
    response[2] = "";
    response[3] = "";

    if (response[0] && response[1])
        RIL_onRequestComplete(t, RIL_E_SUCCESS, &response, sizeof(response));
    else
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);

    free(response[0]);
    free(response[1]);
}

/* Deprecated */
/**
 * RIL_REQUEST_GET_IMEI
 *
 * Get the device IMEI, including check digit.
*/
void requestGetIMEI(void *data, size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen;
    char *imei;

    imei = getDeviceInfo("IMEI Data");
    if (imei)
        RIL_onRequestComplete(t, RIL_E_SUCCESS, imei, sizeof(char *));
    else
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);

    free(imei);
}

/* Deprecated */
/**
 * RIL_REQUEST_GET_IMEISV
 *
 * Get the device IMEISV, which should be two decimal digits.
*/
void requestGetIMEISV(void *data, size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen;
    char *svn;

    /* IMEISV */
    svn = getDeviceInfo("SVN");
    if (svn)
        RIL_onRequestComplete(t, RIL_E_SUCCESS, svn, sizeof(char *));
    else
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);

    free(svn);
}

/**
 * RIL_REQUEST_BASEBAND_VERSION
 *
 * Return string value indicating baseband version, eg
 * response from AT+CGMR.
*/
void requestBasebandVersion(void *data, size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen;
    char *ver;

    ver = getDeviceInfo("Protocol FW Version");
    if (ver)
        RIL_onRequestComplete(t, RIL_E_SUCCESS, ver, sizeof(char *));
    else
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);

    free(ver);
}

/** Do post- SIM ready initialization. */
void onSIMReady(void *p)
{
    int err = 0;
    int screenState;
    char prop[PROPERTY_VALUE_MAX];
    (void) p;

    /* Check if ME is ready to set preferred message storage */
    checkMessageStorageReady(NULL);

    /* Select message service */
    at_send_command("AT+CSMS=0");

   /* Configure new messages indication
    *  mode = 2 - Buffer unsolicited result code in TA when TA-TE link is
    *             reserved(e.g. in on.line data mode) and flush them to the
    *             TE after reservation. Otherwise forward them directly to
    *             the TE.
    *  mt   = 2 - SMS-DELIVERs (except class 2 messages and messages in the
    *             message waiting indication group (store message)) are
    *             routed directly to TE using unsolicited result code:
    *             +CMT: [<alpha>],<length><CR><LF><pdu> (PDU mode)
    *             Class 2 messages are handled as if <mt> = 1
    *  bm   = 2 - New CBMs are routed directly to the TE using unsolicited
    *             result code:
    *             +CBM: <length><CR><LF><pdu> (PDU mode)
    *  ds   = 1 - SMS-STATUS-REPORTs are routed to the TE using unsolicited
    *             result code: +CDS: <length><CR><LF><pdu> (PDU mode)
    *  bfr  = 0 - TA buffer of unsolicited result codes defined within this
    *             command is flushed to the TE when <mode> 1...3 is entered
    *             (OK response is given before flushing the codes).
    */
    at_send_command("AT+CNMI=2,2,2,1,0");

    /* Subscribe to network status events */
    at_send_command("AT*E2REG=1");

    /* Configure Short Message (SMS) Format
     *  mode = 0 - PDU mode.
     */
    at_send_command("AT+CMGF=0");

    /* Subscribe to time zone/NITZ reporting.
     *
     */
    property_get("mbm.ril.config.nitz", prop, "yes");
    if (strstr(prop, "yes")) {
        err = at_send_command("AT*ETZR=3");
        if (err != AT_NOERROR) {
            ALOGD("%s() Degrading nitz to mode 2", __func__);
            at_send_command("AT*ETZR=2");
        }
    } else {
        at_send_command("AT*ETZR=0");
        ALOGW("%s() Network Time Zone (NITZ) disabled!", __func__);
    }

    /* Delete Internet Account Configuration.
     *  Some FW versions has an issue, whereby internet account configuration
     *  needs to be cleared explicitly.
     */
    at_send_command("AT*EIAD=0,0");

    /* Make sure currect screenstate is set */
    getScreenStateLock();
    screenState = getScreenState();
    setScreenState(screenState);
    releaseScreenStateLock();

}

static const char *radioStateToString(RIL_RadioState radioState)
{
    const char *state;

    switch (radioState) {
    case RADIO_STATE_OFF:
        state = "RADIO_STATE_OFF";
        break;
    case RADIO_STATE_UNAVAILABLE:
        state = "RADIO_STATE_UNAVAILABLE";
        break;
    case RADIO_STATE_SIM_NOT_READY:
        state = "RADIO_STATE_SIM_NOT_READY";
        break;
    case RADIO_STATE_SIM_LOCKED_OR_ABSENT:
        state = "RADIO_STATE_SIM_LOCKED_OR_ABSENT";
        break;
    case RADIO_STATE_SIM_READY:
        state = "RADIO_STATE_SIM_READY";
        break;
    case RADIO_STATE_RUIM_NOT_READY:
        state = "RADIO_STATE_RUIM_NOT_READY";
        break;
    case RADIO_STATE_RUIM_READY:
        state = "RADIO_STATE_RUIM_READY";
        break;
    case RADIO_STATE_RUIM_LOCKED_OR_ABSENT:
        state = "RADIO_STATE_RUIM_READY";
        break;
    case RADIO_STATE_NV_NOT_READY:
        state = "RADIO_STATE_NV_NOT_READY";
        break;
    case RADIO_STATE_NV_READY:
        state = "RADIO_STATE_NV_READY";
        break;
    case RADIO_STATE_ON:
        state = "RADIO_STATE_ON";
        break;
    default:
        state = "RADIO_STATE_<> Unknown!";
        break;
    }

    return state;
}

void setRadioState(RIL_RadioState newState)
{
    RIL_RadioState oldState;
    int err;

    if ((err = pthread_mutex_lock(&s_state_mutex)) != 0)
        ALOGE("%s() failed to take state mutex: %s!", __func__, strerror(err));

    oldState = sState;

    ALOGI("%s() oldState=%s newState=%s", __func__, radioStateToString(oldState),
         radioStateToString(newState));

    sState = newState;

    if ((err = pthread_mutex_unlock(&s_state_mutex)) != 0)
        ALOGE("%s() failed to release state mutex: %s!", __func__, strerror(err));

    /* Do these outside of the mutex. */
    if (sState != oldState || sState == RADIO_STATE_SIM_LOCKED_OR_ABSENT) {
        RIL_onUnsolicitedResponse(RIL_UNSOL_RESPONSE_RADIO_STATE_CHANGED,
                                  NULL, 0);

        if (sState == RADIO_STATE_SIM_READY) {
            enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, checkMessageStorageReady, NULL, NULL);
            enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, onSIMReady, NULL, NULL);
        } else if (sState == RADIO_STATE_SIM_NOT_READY)
            enqueueRILEvent(RIL_EVENT_QUEUE_NORMAL, pollSIMState, NULL, NULL);
    }
}

/** Returns 1 if on, 0 if off, and -1 on error. */
int isRadioOn(void)
{
    ATResponse *atresponse = NULL;
    int err;
    char *line;
    int ret;

    err = at_send_command_singleline("AT+CFUN?", "+CFUN:", &atresponse);
    if (err != AT_NOERROR)
        /* Assume radio is off. */
        goto error;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&line, &ret);
    if (err < 0)
        goto error;

    switch (ret) {
        case 1:         /* Full functionality (switched on) */
        case 5:         /* GSM only */
        case 6:         /* WCDMA only */
            ret = 1;
            break;

        default:
            ret = 0;
    }

    at_response_free(atresponse);

    return ret;

error:
    at_response_free(atresponse);
    return -1;
}

/*
 * Retry setting radio power a few times
 * Needed since the module reports EMRDY
 * before it is actually ready. Without
 * this we could get CME ERROR 272 (wwan
 * disabled on host) when sending CFUN=1
 */
int retryRadioPower(void)
{
    int err;
    int i;

    ALOGD("%s()", __func__);
    for (i=0; i<RADIO_POWER_ATTEMPTS; i++) {
        sleep(1);
        err = at_send_command("AT+CFUN=%d", getPreferredNetworkType());
        if (err == AT_NOERROR) {
            return 0;
        }
    }

    return -1;
}

/**
 * RIL_REQUEST_RADIO_POWER
 *
 * Toggle radio on and off (for "airplane" mode).
*/
void requestRadioPower(void *data, size_t datalen, RIL_Token t)
{
    (void) datalen;
    int onOff;
    int err;
    int restricted;

    if (datalen < sizeof(int *)) {
        ALOGE("%s() bad data length!", __func__);
        goto error;
    }

    onOff = ((int *) data)[0];

    if (onOff == 0 && sState != RADIO_STATE_OFF) {
        char value[PROPERTY_VALUE_MAX];

        err = at_send_command("AT+CFUN=4");

        if (err != AT_NOERROR)
            goto error;

        if (property_get("sys.shutdown.requested", value, NULL)) {
            setRadioState(RADIO_STATE_UNAVAILABLE);
            err = at_send_command("AT+CFUN=0");
            if (err != AT_NOERROR)
                goto error;
        } else
            setRadioState(RADIO_STATE_OFF);
    } else if (onOff > 0 && sState == RADIO_STATE_OFF) {
        err = at_send_command("AT+CFUN=%d", getPreferredNetworkType());
        if (err != AT_NOERROR) {
            if (retryRadioPower() < 0)
                goto error;
        }
        setRadioState(RADIO_STATE_SIM_NOT_READY);
    } else {
        ALOGE("%s() Erroneous input", __func__);
        goto error;
    }

    RIL_onRequestComplete(t, RIL_E_SUCCESS, NULL, 0);

    restricted = RIL_RESTRICTED_STATE_NONE;
    RIL_onUnsolicitedResponse(RIL_UNSOL_RESTRICTED_STATE_CHANGED,
                              &restricted, sizeof(int *));

    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
}

/**
 * Synchronous call from the RIL to us to return current radio state.
 * RADIO_STATE_UNAVAILABLE should be the initial state.
 */
RIL_RadioState getRadioState(void)
{
    return sState;
}
                                                                                                                                                                                                                                 u300-ril-device.h                                                                                   0000644 0001750 0001750 00000002014 12271742740 013572  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                #ifndef U300_RIL_INFORMATION_H
#define U300_RIL_INFORMATION_H 1

#include <telephony/ril.h>

void requestGetIMSI(void *data, size_t datalen, RIL_Token t);
void requestDeviceIdentity(void *data, size_t datalen, RIL_Token t);
void requestGetIMEI(void *data, size_t datalen, RIL_Token t);
void requestGetIMEISV(void *data, size_t datalen, RIL_Token t);
void requestBasebandVersion(void *data, size_t datalen, RIL_Token t);

int retryRadioPower(void);
int isRadioOn(void);
void setRadioState(RIL_RadioState newState);
RIL_RadioState getRadioState(void);
void onSIMReady(void *p);
void sendTime(void *p);
char *getTime(void);

void clearDeviceInfo(void);

/* readDeviceInfo needs to be called while unsolicited responses are not yet
 * enabled.
 */
void readDeviceInfo(void);

/* getdeviceInfo returns a pointer to allocated memory of a character string.
 * Note: Caller need to take care of freeing the allocated memory by calling
 * free( ) when the alllocated string is not longer used.
 */
char *getDeviceInfo(const char *info);

#endif
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    u300-ril-error.c                                                                                    0000644 0001750 0001750 00000013677 12271742740 013500  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* Ericsson MBM RIL
 *
 * Copyright (C) Ericsson AB 2011
 * Copyright 2006, The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 *
 */

#include "u300-ril-error.h"

const char *errorCauseToString(int cause)
{
    const char *string;

    switch (cause) {
        case E2NAP_CAUSE_SUCCESS:
            string = "Success";
            break;
        case E2NAP_CAUSE_GPRS_ATTACH_NOT_POSSIBLE:
            string = "GPRS attach not possible";
            break;
        case E2NAP_CAUSE_NO_SIGNAL_CONN:
            string = "No signaling connection";
            break;
        case E2NAP_CAUSE_REACTIVATION_POSSIBLE:
            string = "Reactivation possible";
            break;
        case E2NAP_CAUSE_ACCESS_CLASS_BARRED:
            string = "Access class barred";
            break;
        case GPRS_OP_DETERMINED_BARRING:
            string = "Operator Determined Barring";
            break;
        case GPRS_MBMS_CAPA_INFUFFICIENT:
            string = "MBMS bearer capabilities insufficient for the service";
            break;
        case GPRS_LLC_SNDCP_FAILURE:
            string = "LLC or SNDCP failure";
            break;
        case GPRS_INSUFFICIENT_RESOURCES:
            string = "Insufficient resources";
            break;
        case GPRS_UNKNOWN_APN:
            string = "Unknown or missing access point name";
            break;
        case GPRS_UNKNOWN_PDP_TYPE:
            string = "Unknown PDP address or PDP type";
            break;
        case GPRS_USER_AUTH_FAILURE:
            string = "User authentication failed";
            break;
        case GPRS_ACT_REJECTED_GGSN:
            string = "Activation rejected by GGSN";
            break;
        case GPRS_ACT_REJECTED_UNSPEC:
            string = "Activation rejected, unspecified";
            break;
        case GPRS_SERVICE_OPTION_NOT_SUPP:
            string = "Service option not supported";
            break;
        case GPRS_REQ_SER_OPTION_NOT_SUBS:
            string = "Requested service option not subscribed";
            break;
        case GPRS_SERVICE_OUT_OF_ORDER:
            string = "Service option temporarily out of order";
            break;
        case GPRS_NSAPI_ALREADY_USED:
            string = "NSAPI already used";
            break;
        case GPRS_REGULAR_DEACTIVATION:
            string = "Regular deactivation";
            break;
        case GPRS_QOS_NOT_ACCEPTED:
            string = "QoS not accepted";
            break;
        case GPRS_NETWORK_FAILURE:
            string = "Network failure";
            break;
        case GPRS_REACTIVATION_REQUESTED:
            string = "Reactivation requested";
            break;
        case GPRS_FEATURE_NOT_SUPPORTED:
            string = "Feature not supported";
            break;
        case GRPS_SEMANTIC_ERROR_TFT:
            string = "semantic error in the TFT operation.";
            break;
        case GPRS_SYNTACT_ERROR_TFT:
            string = "syntactical error in the TFT operation.";
            break;
        case GRPS_UNKNOWN_PDP_CONTEXT:
            string = "unknown PDP context";
            break;
        case GPRS_SEMANTIC_ERROR_PF:
            string = "semantic errors in packet filter(s)";
            break;
        case GPRS_SYNTACT_ERROR_PF:
            string = "syntactical error in packet filter(s)";
            break;
        case GPRS_PDP_WO_TFT_ALREADY_ACT:
            string = "PDP context without TFT already activated";
            break;
        case GPRS_MULTICAST_GMEM_TIMEOUT:
            string = "Multicast group membership time-out";
            break;
        case GPRS_ACT_REJECTED_BCM_VIOLATION:
            string = "Activation rejected, Bearer ControlMode violation";
            break;
        case GPRS_INVALID_TRANS_IDENT:
            string = "Invalid transaction identifier value.";
            break;
        case GRPS_SEM_INCORRECT_MSG:
            string = "Semantically incorrect message.";
            break;
        case GPRS_INVALID_MAN_INFO:
            string = "Invalid mandatory information.";
            break;
        case GPRS_MSG_TYPE_NOT_IMPL:
            string = "Message type non-existent or not implemented.";
            break;
        case GPRS_MSG_NOT_COMP_PROTOCOL:
            string = "Message not compatible with protocol state.";
            break;
        case GPRS_IE_NOT_IMPL:
            string = "Information element non-existent or not implemented.";
            break;
        case GPRS_COND_IE_ERROR:
            string = "Conditional IE error.";
            break;
        case GPRS_MSG_NOT_COMP_PROTO_STATE:
            string = "Message not compatible with protocol state.";
            break;
        case GPRS_PROTO_ERROR_UNSPECIFIED:
            string = "Protocol error, unspecified.";
            break;
        case GPRS_APN_RESTRICT_VALUE_INCOMP:
            string = "APN restriction value incompatible with active PDP context.";
            break;
        default:
            string = "E2NAP_CAUSE_<> Unknown!";
            break;
    }

    return string;
}

const char *e2napStateToString(int state)
{
    const char *string;

    switch (state) {
        case E2NAP_STATE_DISCONNECTED:
            string = "Disconnected";
            break;
        case E2NAP_STATE_CONNECTED:
            string = "Connected";
            break;
        case E2NAP_STATE_CONNECTING:
            string = "Connecting";
            break;
        default:
            string = "E2NAP_STATE_<> Unknown!";
            break;
    }

    return string;
}
                                                                 u300-ril-error.h                                                                                    0000644 0001750 0001750 00000010044 12271742740 013466  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
 *
 * Copyright (C) Ericsson AB 2010
 * Copyright 2006, The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 *
 * Author: Indrek Peri <indrek.peri@ericsson.com>
 */

#ifndef U300_RIL_ERROR_H
#define U300_RIL_ERROR_H 1

/*
 Activate PDP and error causes

 # 8: Operator Determined Barring;
 # 26: insufficient resources;
 # 27: missing or unknown APN;
 # 28: unknown PDP address or PDP type;
 # 29: user authentication failed;
 # 30: activation rejected by GGSN;
 # 31: activation rejected, unspecified;
 # 32: service option not supported;
 # 33: requested service option not subscribed;
 # 34: service option temporarily out of order;
 # 35: NSAPI already used. The network shall not send this cause code (only Pre-R99)
 # 40: feature not supported (*)
 # 95 - 111:   protocol errors.
 #112: APN restriction value incompatible with active PDP context.
*/

/*
 Deactivation by MS

 # 25: LLC or SNDCP failure (A/Gb mode only);
 # 26: insufficient resources;
 # 36: regular deactivation; or
 # 37: QoS not accepted.

 Deactivation by network

 # 8:  Operator Determined Barring;
 # 25: LLC or SNDCP failure (A/Gb mode only);
 # 36: regular   deactivation;
 # 38: network failure; or
 # 39: reactivation requested.
 #112: APN restriction value incompatible with active PDP context.

*/

/* 3GPP TS 24.008 V8.4.0 (2008-12) */

#define GPRS_OP_DETERMINED_BARRING   8
#define GPRS_MBMS_CAPA_INFUFFICIENT 24
#define GPRS_LLC_SNDCP_FAILURE      25
#define GPRS_INSUFFICIENT_RESOURCES 26
#define GPRS_UNKNOWN_APN            27
#define GPRS_UNKNOWN_PDP_TYPE       28
#define GPRS_USER_AUTH_FAILURE      29
#define GPRS_ACT_REJECTED_GGSN      30
#define GPRS_ACT_REJECTED_UNSPEC    31
#define GPRS_SERVICE_OPTION_NOT_SUPP 32
#define GPRS_REQ_SER_OPTION_NOT_SUBS 33
#define GPRS_SERVICE_OUT_OF_ORDER   34
#define GPRS_NSAPI_ALREADY_USED     35
#define GPRS_REGULAR_DEACTIVATION   36
#define GPRS_QOS_NOT_ACCEPTED       37
#define GPRS_NETWORK_FAILURE        38
#define GPRS_REACTIVATION_REQUESTED 39
#define GPRS_FEATURE_NOT_SUPPORTED  40
#define GRPS_SEMANTIC_ERROR_TFT     41
#define GPRS_SYNTACT_ERROR_TFT      42
#define GRPS_UNKNOWN_PDP_CONTEXT    43
#define GPRS_SEMANTIC_ERROR_PF      44
#define GPRS_SYNTACT_ERROR_PF       45
#define GPRS_PDP_WO_TFT_ALREADY_ACT 46
#define GPRS_MULTICAST_GMEM_TIMEOUT 47
#define GPRS_ACT_REJECTED_BCM_VIOLATION 48
// Causes releated to invalid messages - beginning
// 95 - 111 protocol errors
#define GPRS_INVALID_TRANS_IDENT    81
#define GRPS_SEM_INCORRECT_MSG      95
#define GPRS_INVALID_MAN_INFO       96
#define GPRS_MSG_TYPE_NOT_IMPL      97
#define GPRS_MSG_NOT_COMP_PROTOCOL  98
#define GPRS_IE_NOT_IMPL            99
#define GPRS_COND_IE_ERROR          100
#define GPRS_MSG_NOT_COMP_PROTO_STATE 101
#define GPRS_PROTO_ERROR_UNSPECIFIED 111
// Causes releated to invalid messages - end
#define GPRS_APN_RESTRICT_VALUE_INCOMP 112

/* State of USB Ethernet interface */
// State
#define E2NAP_STATE_UNKNOWN        -1
#define E2NAP_STATE_DISCONNECTED   0
#define E2NAP_STATE_CONNECTED      1
#define E2NAP_STATE_CONNECTING     2
// Cause
#define E2NAP_CAUSE_UNKNOWN                     -1
#define E2NAP_CAUSE_SUCCESS                     0
#define E2NAP_CAUSE_GPRS_ATTACH_NOT_POSSIBLE    1
#define E2NAP_CAUSE_NO_SIGNAL_CONN              2
#define E2NAP_CAUSE_REACTIVATION_POSSIBLE       3
#define E2NAP_CAUSE_ACCESS_CLASS_BARRED         4
// 8 - 112 in 3GPP TS 24.008 
#define E2NAP_CAUSE_MAXIMUM 255

void mbm_check_error_cause(void);

const char *errorCauseToString(int cause);
const char *e2napStateToString(int state);

#endif
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            u300-ril.h                                                                                          0000644 0001750 0001750 00000003612 12271742740 012342  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#ifndef U300_RIL_H
#define U300_RIL_H 1

#define enqueueRILEvent(isPrio, callback, \
                     param, relativeTime) \
        enqueueRILEventName(isPrio, callback, \
                     param, relativeTime, #callback)

void getScreenStateLock(void);
int getScreenState(void);
void setScreenState(int screenState);
void releaseScreenStateLock(void);

extern char* ril_iface;
extern const struct RIL_Env *s_rilenv;

#define RIL_onRequestComplete(t, e, response, responselen) s_rilenv->OnRequestComplete(t,e, response, responselen)
#define RIL_onUnsolicitedResponse(a,b,c) s_rilenv->OnUnsolicitedResponse(a,b,c)

void enqueueRILEventName(int isPrio, void (*callback) (void *param),
                     void *param, const struct timespec *relativeTime, char *name);

#define RIL_EVENT_QUEUE_NORMAL 0
#define RIL_EVENT_QUEUE_PRIO 1
#define RIL_EVENT_QUEUE_ALL 2

#define RIL_CID_IP 1

/* Maximum number of neighborhood cells is set based on AT specification.
 * Can handle maximum of 16, including the current cell. */
#define MAX_NUM_NEIGHBOR_CELLS 15

#endif
                                                                                                                      u300-ril-messaging.c                                                                                0000644 0001750 0001750 00000054660 12316215230 014306  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#include <stdio.h>
#include <telephony/ril.h>
#include "atchannel.h"
#include "at_tok.h"
#include "misc.h"
#include "u300-ril.h"
#include "u300-ril-device.h"

#define LOG_TAG "RIL"
#include <utils/Log.h>

static char s_outstanding_acknowledge = 0;

/* Outstanding types as bit fields, need to be 2^n */
#define OUTSTANDING_SMS    1
#define OUTSTANDING_STATUS 2
#define OUTSTANDING_CB     4

#define MESSAGE_STORAGE_READY_TIMER 3

#define BSM_LENGTH 88

struct held_pdu {
    char type;
    char *sms_pdu;
    int len;
    struct held_pdu *next;
};

static pthread_mutex_t s_held_pdus_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct held_pdu *s_held_pdus = NULL;

static struct held_pdu *dequeue_held_pdu(char types)
{
    struct held_pdu *hpdu = s_held_pdus;
    struct held_pdu *hpdu_prev = NULL;
    while (hpdu != NULL) {
        if (hpdu->type & types) {
            if (s_held_pdus == hpdu)
                s_held_pdus = hpdu->next;
            if (hpdu_prev)
                hpdu_prev->next = hpdu->next;
            hpdu->next = NULL;
            break;
        } else {
            hpdu_prev = hpdu;
            hpdu = hpdu->next;
        }
    }

    return hpdu;
}

static void enqueue_held_pdu(char type, const char *sms_pdu, int len)
{
    struct held_pdu *hpdu = malloc(sizeof(*hpdu));
    if (hpdu == NULL) {
        ALOGE("%s() failed to allocate memory!", __func__);
        return;
    }

    memset(hpdu, 0, sizeof(*hpdu));
    hpdu->type = type;
    hpdu->len = len;
    hpdu->sms_pdu = malloc(len+1);
    if (NULL == hpdu->sms_pdu) {
        ALOGE("%s() failed to allocate memory!", __func__);
        free(hpdu);
        return;
    }
    memcpy(hpdu->sms_pdu, sms_pdu, len);
    hpdu->sms_pdu[len] = '\0';

    if (s_held_pdus == NULL)
       s_held_pdus = hpdu;
    else {
        struct held_pdu *p = s_held_pdus;
        while (p->next != NULL)
            p = p->next;

        p->next = hpdu;
    }
}

void isSimSmsStorageFull(void *p)
{
    ATResponse *atresponse = NULL;
    char *tok = NULL;
    char* storage_area = NULL;
    int used1, total1;
    int err;
    (void) p;

    err = at_send_command_singleline("AT+CPMS?", "+CPMS: ", &atresponse);
    if (err != AT_NOERROR)
        goto error;

    tok = atresponse->p_intermediates->line;

    err = at_tok_start(&tok);
    if (err < 0)
        goto error;

    err = at_tok_nextstr(&tok, &storage_area);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&tok, &used1);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&tok, &total1);
    if (err < 0)
        goto error;

    if (used1 >= total1)
        RIL_onUnsolicitedResponse(RIL_UNSOL_SIM_SMS_STORAGE_FULL, NULL, 0);

    goto exit;

error:
    ALOGE("%s() failed during AT+CPMS sending/handling!", __func__);
exit:
    at_response_free(atresponse);
    return;
}

void onNewSms(const char *sms_pdu)
{
    pthread_mutex_lock(&s_held_pdus_mutex);

    /* No RIL_UNSOL_RESPONSE_NEW_SMS or RIL_UNSOL_RESPONSE_NEW_SMS_STATUS_REPORT
     * messages should be sent until a RIL_REQUEST_SMS_ACKNOWLEDGE has been received for
     * previous new SMS or status.
     */
    if (s_outstanding_acknowledge) {
        ALOGI("%s() Waiting for ack for previous sms/status, enqueue PDU..", __func__);
        enqueue_held_pdu(OUTSTANDING_SMS, sms_pdu, strlen(sms_pdu));
    } else {
        s_outstanding_acknowledge = 1;
        RIL_onUnsolicitedResponse(RIL_UNSOL_RESPONSE_NEW_SMS,
                                  sms_pdu, strlen(sms_pdu));
    }

    pthread_mutex_unlock(&s_held_pdus_mutex);
}

void onNewStatusReport(const char *sms_pdu)
{
    char *response = NULL;
    int err;

    /* Baseband will not prepend SMSC addr, but Android expects it. */
    err = asprintf(&response, "%s%s", "00", sms_pdu);
    if (err == -1) {
        ALOGD("%s() Error allocating memory!", __func__);
        return;
    }

    pthread_mutex_lock(&s_held_pdus_mutex);

    /* No RIL_UNSOL_RESPONSE_NEW_SMS or RIL_UNSOL_RESPONSE_NEW_SMS_STATUS_REPORT
     * messages should be sent until a RIL_REQUEST_SMS_ACKNOWLEDGE has been received for
     * previous new SMS or status.
     */
    if (s_outstanding_acknowledge) {
        ALOGI("%s() Waiting for ack for previous sms/status, enqueue PDU..", __func__);
        enqueue_held_pdu(OUTSTANDING_STATUS, response, strlen(response));
    } else {
        s_outstanding_acknowledge = 1;
        RIL_onUnsolicitedResponse(RIL_UNSOL_RESPONSE_NEW_SMS_STATUS_REPORT,
                                  response, strlen(response));
    }
    free(response);
    pthread_mutex_unlock(&s_held_pdus_mutex);
}

void onNewBroadcastSms(const char *pdu)
{
    char *message = NULL;
    ALOGD("%s() Length : %d", __func__, strlen(pdu));

    if (strlen(pdu) != (2 * BSM_LENGTH)) {
        ALOGE("%s() Broadcast Message length error! Discarding!", __func__);
        goto error;
    }
    ALOGD("%s() PDU: %176s", __func__, pdu);

    message = alloca(BSM_LENGTH);
    if (!message) {
        ALOGE("%s() error allocating memory for message! Discarding!", __func__);
        goto error;
    }

    stringToBinary(pdu, 2*BSM_LENGTH, (unsigned char *)message);

    pthread_mutex_lock(&s_held_pdus_mutex);

    /* Don't RIL_UNSOL_RESPONSE_NEW_CB until an outstanding
     * RIL_REQUEST_SMS_ACKNOWLEDGE has been received.
     */
    if (s_outstanding_acknowledge) {
        ALOGI("%s() Waiting for ack for previous sms/status, enqueue PDU..", __func__);
        enqueue_held_pdu(OUTSTANDING_CB, message, BSM_LENGTH);
    } else {
        RIL_onUnsolicitedResponse(RIL_UNSOL_RESPONSE_NEW_BROADCAST_SMS,
                              message, BSM_LENGTH);
    }

    pthread_mutex_unlock(&s_held_pdus_mutex);

error:
    return;
}

void onNewSmsOnSIM(const char *s)
{
    char *line;
    char *mem;
    char *tok;
    int err = 0;
    int index = -1;

    tok = line = strdup(s);

    err = at_tok_start(&tok);
    if (err < 0)
        goto error;

    err = at_tok_nextstr(&tok, &mem);
    if (err < 0)
        goto error;

    if (strncmp(mem, "SM", 2) != 0)
        goto error;

    err = at_tok_nextint(&tok, &index);
    if (err < 0)
        goto error;

    RIL_onUnsolicitedResponse(RIL_UNSOL_RESPONSE_NEW_SMS_ON_SIM,
                              &index, sizeof(int *));

finally:
    free(line);
    return;

error:
    ALOGE("%s() Failed to parse +CMTI.", __func__);
    goto finally;
}

#define BROADCAST_MAX_RANGES_SUPPORTED 10

/**
 * RIL_REQUEST_GSM_GET_BROADCAST_SMS_CONFIG
 */
void requestGSMGetBroadcastSMSConfig(void *data, size_t datalen,
                                     RIL_Token t)
{
    ATResponse *atresponse = NULL;
    int mode, err = 0;
    unsigned int i, count = 0;
    char *mids;
    char *range;
    char *trange;
    char *tok = NULL;

    (void) data; (void) datalen;

    RIL_GSM_BroadcastSmsConfigInfo *configInfo[BROADCAST_MAX_RANGES_SUPPORTED];

    err = at_send_command_singleline("AT+CSCB?", "+CSCB:", &atresponse);

    if (err != AT_NOERROR)
        goto error;

    tok = atresponse->p_intermediates->line;

    err = at_tok_start(&tok);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&tok, &mode);
    if (err < 0)
        goto error;

    /**
     * Get the string that yields the service ids (mids). AT+CSCB <mids>
     * parameter may contain a mix of single service ids (,%d,) and service id
     * ranges (,%d-%d,).
     */
    err = at_tok_nextstr(&tok, &mids);
    if (err < 0)
        goto error;

    while (at_tok_nextstr(&mids, &range) == 0) {
        /**
         * Replace any '-' sign with ',' sign to allow for at_tok_nextint
         * for both fromServiceId and toServiceId below.
         */
        trange = range;
        while ((NULL != trange) && ('\0' != *trange)) {
            if ('-' == *trange)
                *trange = ',';
            trange++;
        }
        if (count < BROADCAST_MAX_RANGES_SUPPORTED) {
            configInfo[count] = calloc(1,
                sizeof(RIL_GSM_BroadcastSmsConfigInfo));
            if (NULL == configInfo[count])
                goto error;

            /* No support for "Not accepted mids", selected is always 1 */
            configInfo[count]->selected = 1;

            /* Fetch fromServiceId value */
            err = at_tok_nextint(&range, &(configInfo[count]->fromServiceId));
            if (err < 0)
                goto error;
            /* Try to fetch toServiceId value if it exist */
            err = at_tok_nextint(&range, &(configInfo[count]->toServiceId));
            if (err < 0)
                configInfo[count]->toServiceId =
                    configInfo[count]->fromServiceId;

            count++;
        } else {
            ALOGW("%s() Max limit (%d) passed, can not send all ranges "
                 "reported by modem.", __func__,
                 BROADCAST_MAX_RANGES_SUPPORTED);
            break;
        }
    }

    RIL_onRequestComplete(t, RIL_E_SUCCESS, &configInfo,
                          sizeof(RIL_GSM_BroadcastSmsConfigInfo *) * count);

    goto exit;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);

exit:
    at_response_free(atresponse);
    for (i = 0; i < count; i++)
        free(configInfo[i]);
}

/**
 * RIL_REQUEST_GSM_SET_BROADCAST_SMS_CONFIG
 */
void requestGSMSetBroadcastSMSConfig(void *data, size_t datalen,
                                     RIL_Token t)
{
    int err, count, i;
    char *tmp, *mids = NULL;
    RIL_GSM_BroadcastSmsConfigInfo **configInfoArray =
        (RIL_GSM_BroadcastSmsConfigInfo **) data;
    RIL_GSM_BroadcastSmsConfigInfo *configInfo = NULL;

    count = datalen / sizeof(RIL_GSM_BroadcastSmsConfigInfo *);
    ALOGI("Number of MID ranges in BROADCAST_SMS_CONFIG: %d", count);

    for (i = 0; i < count; i++) {
        configInfo = configInfoArray[i];
        /* No support for "Not accepted mids" in AT */
        if (configInfo->selected) {
            tmp = mids;
            asprintf(&mids, "%s%d-%d%s", (tmp ? tmp : ""),
                configInfo->fromServiceId, configInfo->toServiceId,
                (i == (count - 1) ? "" : ",")); /* Last one? Skip comma */
            free(tmp);
        }
    }

    if (mids == NULL) {
	RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
	return;
    }

    err = at_send_command("AT+CSCB=0,\"%s\"", mids);
    free(mids);

    if (err != AT_NOERROR) {
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
	return;
    }

    RIL_onRequestComplete(t, RIL_E_SUCCESS, NULL, 0);
}

/**
 * RIL_REQUEST_GSM_SMS_BROADCAST_ACTIVATION
 */
void requestGSMSMSBroadcastActivation(void *data, size_t datalen,
                                      RIL_Token t)
{
    ATResponse *atresponse = NULL;
    int mode, mt, bm, ds, bfr, skip;
    int activation;
    char *tok;
    int err;

    (void) datalen;

    /* AT+CNMI=[<mode>[,<mt>[,<bm>[,<ds>[,<bfr>]]]]] */
    err = at_send_command_singleline("AT+CNMI?", "+CNMI:", &atresponse);
    if (err != AT_NOERROR)
        goto error;

    tok = atresponse->p_intermediates->line;

    err = at_tok_start(&tok);
    if (err < 0)
        goto error;
    err = at_tok_nextint(&tok, &mode);
    if (err < 0)
        goto error;
    err = at_tok_nextint(&tok, &mt);
    if (err < 0)
        goto error;
    err = at_tok_nextint(&tok, &skip);
    if (err < 0)
        goto error;
    err = at_tok_nextint(&tok, &ds);
    if (err < 0)
        goto error;
    err = at_tok_nextint(&tok, &bfr);
    if (err < 0)
        goto error;

    /* 0 - Activate, 1 - Turn off */
    activation = *((const int *)data);
    if (activation == 0)
        bm = 2;
    else
        bm = 0;

    err = at_send_command("AT+CNMI=%d,%d,%d,%d,%d", mode, mt, bm, ds, bfr);

    if (err != AT_NOERROR)
        goto error;

    RIL_onRequestComplete(t, RIL_E_SUCCESS, NULL, 0);

finally:
    at_response_free(atresponse);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    goto finally;
}


/**
 * RIL_REQUEST_SEND_SMS
 *
 * Sends an SMS message.
*/
void requestSendSMS(void *data, size_t datalen, RIL_Token t)
{
    (void) datalen;
    int err, aterr;
    const char *smsc;
    const char *pdu;
    char *line;
    int tpLayerLength;
    char *cmd1, *cmd2;
    RIL_SMS_Response response;
    RIL_Errno ret = RIL_E_SUCCESS;
    ATResponse *atresponse = NULL;

    smsc = ((const char **) data)[0];
    pdu = ((const char **) data)[1];

    tpLayerLength = strlen(pdu) / 2;

    /* NULL for default SMSC. */
    if (smsc == NULL)
        smsc = "00";

    asprintf(&cmd1, "AT+CMGS=%d", tpLayerLength);
    asprintf(&cmd2, "%s%s", smsc, pdu);

    aterr = at_send_command_sms(cmd1, cmd2, "+CMGS:", &atresponse);
    free(cmd1);
    free(cmd2);

    if (aterr != AT_NOERROR)
        goto error;

    memset(&response, 0, sizeof(response));
   /* Set errorCode to -1 if unknown or not applicable
    * See 3GPP 27.005, 3.2.5 for GSM/UMTS
    */
    response.errorCode = -1;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&line, &response.messageRef);
    if (err < 0)
        goto error;

    /* No support for ackPDU. Do we need it? */
    RIL_onRequestComplete(t, RIL_E_SUCCESS, &response, sizeof(response));

finally:
    at_response_free(atresponse);
    return;

error:
    switch (at_get_cms_error(aterr)) {
    case CMS_NO_NETWORK_SERVICE:
    case CMS_NETWORK_TIMEOUT:
        ret = RIL_E_SMS_SEND_FAIL_RETRY;
        break;
    default:
        ret = RIL_E_GENERIC_FAILURE;
        break;
    }
    RIL_onRequestComplete(t, ret, NULL, 0);
    goto finally;
}

/**
 * RIL_REQUEST_SEND_SMS_EXPECT_MORE
 *
 * Send an SMS message. Identical to RIL_REQUEST_SEND_SMS,
 * except that more messages are expected to be sent soon. If possible,
 * keep SMS relay protocol link open (eg TS 27.005 AT+CMMS command).
*/
void requestSendSMSExpectMore(void *data, size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen;
    /* Throw the command on the channel and ignore any errors, since we
       need to send the SMS anyway and subsequent SMSes will be sent anyway. */
    at_send_command("AT+CMMS=1");

    requestSendSMS(data, datalen, t);
}

/**
 * RIL_REQUEST_SMS_ACKNOWLEDGE
 *
 * Acknowledge successful or failed receipt of SMS previously indicated
 * via RIL_UNSOL_RESPONSE_NEW_SMS .
*/
void requestSMSAcknowledge(void *data, size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen;
    struct held_pdu *hpdu;

    RIL_onRequestComplete(t, RIL_E_SUCCESS, NULL, 0);

    pthread_mutex_lock(&s_held_pdus_mutex);

    /* Prioritize any outstanding pdu with a type that need an ACK, and when
     * reaching outstanding pdus with a type that don't need an ACK, just send
     * them all.
     */
    while (1) {
        hpdu = dequeue_held_pdu(OUTSTANDING_SMS | OUTSTANDING_STATUS);
        if (NULL == hpdu)
            hpdu = dequeue_held_pdu(OUTSTANDING_CB);

        if (hpdu != NULL) {
            ALOGE("%s() Outstanding requests in queue, dequeueing and sending.",
             __func__);
            int unsolResponse = 0;
            char type = hpdu->type;

            if (hpdu->type == OUTSTANDING_SMS)
                unsolResponse = RIL_UNSOL_RESPONSE_NEW_SMS;
            else if (hpdu->type == OUTSTANDING_CB)
                unsolResponse = RIL_UNSOL_RESPONSE_NEW_BROADCAST_SMS;
            else
                unsolResponse = RIL_UNSOL_RESPONSE_NEW_SMS_STATUS_REPORT;

            RIL_onUnsolicitedResponse(unsolResponse, hpdu->sms_pdu, hpdu->len);

            free(hpdu->sms_pdu);
            free(hpdu);

            if (OUTSTANDING_CB != type)
                /* Still need an ACK. Break out of the loop */
                break;
        } else {
            s_outstanding_acknowledge = 0;
            break;
        }
    }

    pthread_mutex_unlock(&s_held_pdus_mutex);
}

/**
 * RIL_REQUEST_WRITE_SMS_TO_SIM
 *
 * Stores a SMS message to SIM memory.
*/
void requestWriteSmsToSim(void *data, size_t datalen, RIL_Token t)
{
    RIL_SMS_WriteArgs *args;
    char *cmd;
    char *pdu;
    char *line;
    int length;
    int index;
    int err;
    ATResponse *atresponse = NULL;

    (void) datalen;

    args = (RIL_SMS_WriteArgs *) data;

    length = strlen(args->pdu) / 2;
    err = asprintf(&cmd, "AT+CMGW=%d,%d", length, args->status);
    if (err == -1)
        goto error;
    err = asprintf(&pdu, "%s%s", (args->smsc ? args->smsc : "00"), args->pdu);
    if (err == -1)
        goto error;

    err = at_send_command_sms(cmd, pdu, "+CMGW:", &atresponse);
    free(cmd);
    free(pdu);

    if (err != AT_NOERROR)
        goto error;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&line, &index);
    if (err < 0)
        goto error;

    RIL_onRequestComplete(t, RIL_E_SUCCESS, &index, sizeof(int *));

finally:
    at_response_free(atresponse);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    goto finally;
}

/**
 * RIL_REQUEST_DELETE_SMS_ON_SIM
 *
 * Deletes a SMS message from SIM memory.
 */
void requestDeleteSmsOnSim(void *data, size_t datalen, RIL_Token t)
{
    int err;
    (void) data; (void) datalen;

    err = at_send_command("AT+CMGD=%d", ((int *) data)[0]);
    if (err != AT_NOERROR)
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    else
        RIL_onRequestComplete(t, RIL_E_SUCCESS, NULL, 0);
}

/**
 * RIL_REQUEST_GET_SMSC_ADDRESS
 */
void requestGetSMSCAddress(void *data, size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen;
    ATResponse *atresponse = NULL;
    int err;
    char *line;
    char *response;

    err = at_send_command_singleline("AT+CSCA?", "+CSCA:", &atresponse);

    if (err != AT_NOERROR)
        goto error;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    err = at_tok_nextstr(&line, &response);
    if (err < 0)
        goto error;

    RIL_onRequestComplete(t, RIL_E_SUCCESS, response, sizeof(char *));

finally:
    at_response_free(atresponse);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    goto finally;
}

/**
 * RIL_REQUEST_SET_SMSC_ADDRESS
 */
void requestSetSMSCAddress(void *data, size_t datalen, RIL_Token t)
{
    (void) datalen;
    int err;
    const char *smsc = (const char *)data;

    err = at_send_command("AT+CSCA=\"%s\"", smsc);
    if (err != AT_NOERROR)
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    else
        RIL_onRequestComplete(t, RIL_E_SUCCESS, NULL, 0);
}

/**
 * RIL_REQUEST_REPORT_SMS_MEMORY_STATUS
 */
void requestSmsStorageFull(void *data, size_t datalen, RIL_Token t)
{
    int ack;
    int err;
    (void) data; (void) datalen; (void) err;

    ack = ((int *) data)[0];

    /* Android will call RIL_REQUEST_REPORT_SMS_MEMORY_STATUS in case of:
     * 0. memory is full
     * 1. memory was full and been cleaned up, inform modem memory is available now.
     */
    switch (ack) {
    case 0:
        /* Android will handle this, no need to inform modem. always return success. */
        ALOGI("SMS storage full");
        break;

    case 1:
        /* Since we are not using +CNMA command. It's fine to return without informing network */
        ALOGI("Failed to inform network for Message Cleanup. Need cmd : ESMSMEMAVAIL");
        break;

    default:
        ALOGE("%s() Invalid parameter", __func__);
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
        return;
    }

    RIL_onRequestComplete(t, RIL_E_SUCCESS, NULL, 0);
}

/**
 * RIL_UNSOL_SIM_SMS_STORAGE_FULL
 *
 * SIM SMS storage area is full, cannot receive
 * more messages until memory freed
 */
void onNewSmsIndication(void)
{
    enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, isSimSmsStorageFull, NULL, NULL);
}

/*
 * Configure preferred message storage
 *  mem1 = SM, mem2 = SM
 */
int setPreferredMessageStorage(void)
{
    ATResponse *atresponse = NULL;
    char *tok = NULL;
    int used1, total1;
    int err;
    int return_value;

    err = at_send_command_singleline("AT+CPMS=\"SM\",\"SM\"","+CPMS: ", &atresponse);
    if (err != AT_NOERROR) {
        ALOGE("%s() Unable to set preferred message storage", __func__);
        goto error;
    }

    /*
     * Depending on the host boot time the indication that message storage
     * on SIM is full (+CIEV: 10,1) may be sent before the RIL is started.
     * The RIL will explicitly check status of SIM messages storage using
     * +CPMS intermediate response and inform Android if storage is full.
     * +CPMS: <used1>,<total1>,<used2>,<total2>,<used3>,<total3>
     */
    tok = atresponse->p_intermediates->line;

    err = at_tok_start(&tok);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&tok, &used1);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&tok, &total1);
    if (err < 0)
        goto error;

    if (used1 >= total1)
        RIL_onUnsolicitedResponse(RIL_UNSOL_SIM_SMS_STORAGE_FULL,NULL, 0);

    return_value = 0;

    goto exit;

error:
    ALOGE("%s() Failed during AT+CPMS sending/handling!", __func__);
    return_value = 1;

exit:
    at_response_free(atresponse);
    return return_value;
}

/* Check if ME is ready to set preferred message storage */
void checkMessageStorageReady(void *p)
{
    int err;
    struct timespec trigger_time;
    (void) p;

    if (RADIO_STATE_SIM_READY != getRadioState()) {
        ALOGE("%s() SIM not ready, aborting!", __func__);
        return;
    }

    err = at_send_command_singleline("AT+CPMS?","+CPMS: ", NULL);
    if (err == AT_NOERROR) {
        if (setPreferredMessageStorage() == 0) {
            ALOGI("Message storage is ready");
            return;
        }
    }

    ALOGE("%s() Message storage is not ready"
         "A new attempt will be done in %d seconds",
         __func__, MESSAGE_STORAGE_READY_TIMER);

    trigger_time.tv_sec = MESSAGE_STORAGE_READY_TIMER;
    trigger_time.tv_nsec = 0;

    enqueueRILEvent(RIL_EVENT_QUEUE_PRIO,
        checkMessageStorageReady, NULL, &trigger_time);
}
                                                                                u300-ril-messaging.h                                                                                0000644 0001750 0001750 00000003742 12271742740 014321  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#ifndef U300_RIL_MESSAGING_H
#define U300_RIL_MESSAGING_H

void onNewSms(const char *sms_pdu);
void onNewStatusReport(const char *sms_pdu);
void onNewBroadcastSms(const char *sms_pdu);
void onNewSmsOnSIM(const char* s);
void onNewSmsIndication(void);
void requestSendSMS(void *data, size_t datalen, RIL_Token t);
void requestSendSMSExpectMore(void *data, size_t datalen, RIL_Token t);
void requestSMSAcknowledge(void *data, size_t datalen, RIL_Token t);
void requestWriteSmsToSim(void *data, size_t datalen, RIL_Token t);
void requestDeleteSmsOnSim(void *data, size_t datalen, RIL_Token t);
void requestGetSMSCAddress(void *data, size_t datalen, RIL_Token t);
void requestSetSMSCAddress(void *data, size_t datalen, RIL_Token t);
void requestSmsStorageFull(void *data, size_t datalen, RIL_Token t);
void requestGSMGetBroadcastSMSConfig(void *data, size_t datalen, RIL_Token t);
void requestGSMSetBroadcastSMSConfig(void *data, size_t datalen, RIL_Token t);
void requestGSMSMSBroadcastActivation(void *data, size_t datalen, RIL_Token t);
void isSimSmsStorageFull(void *p);
void checkMessageStorageReady(void *p);
int setPreferredMessageStorage(void);

#endif
                              u300-ril-network.c                                                                                  0000644 0001750 0001750 00000214765 12316216472 014037  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#include <stdio.h>
#include <telephony/ril.h>
#include <assert.h>
#include "atchannel.h"
#include "at_tok.h"
#include "misc.h"
#include "u300-ril.h"
#include "u300-ril-error.h"
#include "u300-ril-messaging.h"
#include "u300-ril-network.h"
#include "u300-ril-sim.h"
#include "u300-ril-pdp.h"
#include "u300-ril-device.h"
#include <arpa/inet.h>
#include "net-utils.h"

#define LOG_TAG "RIL"
#include <utils/Log.h>
#include <cutils/properties.h>

#define REPOLL_OPERATOR_SELECTED 360     /* 6 minutes OK? */
#define MAX_NITZ_LENGTH 32

static const struct timespec TIMEVAL_OPERATOR_SELECT_POLL = { 1, 0 };

static char last_nitz_time[MAX_NITZ_LENGTH];

static int s_creg_stat = 4, s_creg_lac = -1, s_creg_cid = -1;
static int s_cgreg_stat = 4, s_cgreg_lac = -1, s_cgreg_cid = -1, s_cgreg_act = -1;

static int s_gsm_rinfo = 0, s_umts_rinfo = 0;
static int s_reg_change = 0;
static int s_cops_mode = -1;
static int rssi_queue = 0;

static void pollOperatorSelected(void *params);

/*
 * s_registrationDeniedReason is used to keep track of registration deny
 * reason for which is called by pollOperatorSelected from
 * RIL_REQUEST_SET_NETWORK_SELECTION_AUTOMATIC, so that in case
 * of invalid SIM/ME, Android will not continuously poll for operator.
 *
 * s_registrationDeniedReason is set when receives the registration deny
 * and detail reason from "AT*E2REG?" command, and is reset to
 * DEFAULT_VALUE otherwise.
 */
static CsReg_Deny_DetailReason s_registrationDeniedReason = DEFAULT_VALUE;

/*
 * variable and defines to keep track of preferred network type
 * the PREF_NET_TYPE defines correspond to CFUN arguments for
 * different radio states
 */
#define PREF_NET_TYPE_3G 1
#define PREF_NET_TYPE_2G_ONLY 5
#define PREF_NET_TYPE_3G_ONLY 6

static int pref_net_type = PREF_NET_TYPE_3G;

struct operatorPollParams {
    RIL_Token t;
    int loopcount;
};

/* +CGREG AcT values */
enum CREG_AcT {
    CGREG_ACT_GSM               = 0,
    CGREG_ACT_GSM_COMPACT       = 1, /* Not Supported */
    CGREG_ACT_UTRAN             = 2,
    CGREG_ACT_GSM_EGPRS         = 3,
    CGREG_ACT_UTRAN_HSDPA       = 4,
    CGREG_ACT_UTRAN_HSUPA       = 5,
    CGREG_ACT_UTRAN_HSUPA_HSDPA = 6,
    CGREG_ACT_UTRAN_HSPAP       = 7  /* Dummy Value for HSPA Evol */
};

/* +CGREG stat values */
enum CREG_stat {
    CGREG_STAT_NOT_REG            = 0,
    CGREG_STAT_REG_HOME_NET       = 1,
    CGREG_STAT_NOT_REG_SEARCHING  = 2,
    CGREG_STAT_REG_DENIED         = 3,
    CGREG_STAT_UNKNOWN            = 4,
    CGREG_STAT_ROAMING            = 5
};

/* *ERINFO umts_info values */
enum ERINFO_umts {
    ERINFO_UMTS_NO_UMTS_HSDPA     = 0,
    ERINFO_UMTS_UMTS              = 1,
    ERINFO_UMTS_HSDPA             = 2,
    ERINFO_UMTS_HSPA_EVOL         = 3
};

#define E2REG_UNKNOWN                   -1
#define E2REG_DETACHED                  0
#define E2REG_IN_PROGRESS               1
#define E2REG_ACCESS_CLASS_BARRED       2   /* BARRED */
#define E2REG_NO_RESPONSE               3
#define E2REG_PENDING                   4
#define E2REG_REGISTERED                5
#define E2REG_PS_ONLY_SUSPENDED         6
#define E2REG_NO_ALLOWABLE_PLMN         7   /* Forbidden NET */
#define E2REG_PLMN_NOT_ALLOWED          8   /* Forbidden NET */
#define E2REG_LA_NOT_ALLOWED            9   /* Forbidden NET */
#define E2REG_ROAMING_NOT_ALLOWED       10  /* Forbidden NET */
#define E2REG_PS_ONLY_GPRS_NOT_ALLOWED  11  /* Forbidden NET */
#define E2REG_NO_SUITABLE_CELLS         12  /* Forbidden NET */
#define E2REG_INVALID_SIM_AUTH          13  /* Invalid SIM */
#define E2REG_INVALID_SIM_CONTENT       14  /* Invalid SIM */
#define E2REG_INVALID_SIM_LOCKED        15  /* Invalid SIM */
#define E2REG_INVALID_SIM_IMSI          16  /* Invalid SIM */
#define E2REG_INVALID_SIM_ILLEGAL_MS    17  /* Invalid SIM */
#define E2REG_INVALID_SIM_ILLEGAL_ME    18  /* Invalid SIM */
#define E2REG_PS_ONLY_INVALID_SIM_GPRS  19  /* Invalid SIM */
#define E2REG_INVALID_SIM_NO_GPRS       20  /* Invalid SIM */

static int s_cs_status = E2REG_UNKNOWN;
static int s_ps_status = E2REG_UNKNOWN;

static const struct timespec NORMAL_FAST_DORMANCY_POLL = { 5, 0 };
static const struct timespec SLOW_FAST_DORMANCY_POLL = { 10, 0 };

static unsigned long long old_rx_packets;
static unsigned long long old_tx_packets;

static void pollFastDormancy(void *params);

void startPollFastDormancy(void)
{
    int err;
    err = ifc_statistics(ril_iface, &old_rx_packets, &old_tx_packets);
    if (err == -1)
        ALOGE("%s() Unable to read /proc/net/dev. FD disabled!", __func__);
    else if (err == 1)
        ALOGE("%s() Interface (%s) not found. FD disabled!", __func__, ril_iface);
    else {
        enqueueRILEventName(RIL_EVENT_QUEUE_NORMAL, pollFastDormancy, NULL,
                                        &NORMAL_FAST_DORMANCY_POLL, NULL);
        ALOGI("%s() Enabled Fast Dormancy!", __func__ );
    }
}

/**
 * Poll interface to see if we are able to enter
 * Fast Dormancy.
 */
static void pollFastDormancy(void *params)
{
    (void) params;
    int err;
    unsigned long long rx_packets;
    unsigned long long tx_packets;
    static int dormant = 0;

    /* First check that we still are connected*/
    if (getE2napState() != E2NAP_STATE_CONNECTED) {
        ALOGI("%s() Connection Lost. Disabled Fast Dormancy!", __func__ );
        return;
    }

    /* Check that we are registered */
    if ((s_cs_status != E2REG_REGISTERED) && (s_ps_status != E2REG_REGISTERED)) {
        ALOGI("%s() Registration lost (Restricted). Slow Dormancy!", __func__ );
        enqueueRILEventName(RIL_EVENT_QUEUE_NORMAL, pollFastDormancy, NULL,
                                        &SLOW_FAST_DORMANCY_POLL, NULL);
        return;
    }

    /* Check that we are registered */
    if (!(s_creg_stat == CGREG_STAT_REG_HOME_NET ||
        s_creg_stat == CGREG_STAT_ROAMING ||
        s_cgreg_stat == CGREG_STAT_REG_HOME_NET ||
        s_cgreg_stat == CGREG_STAT_ROAMING)) {
        ALOGI("%s() Registration lost. Slow Dormancy!", __func__ );
        enqueueRILEventName(RIL_EVENT_QUEUE_NORMAL, pollFastDormancy, NULL,
                                        &SLOW_FAST_DORMANCY_POLL, NULL);
        return;
    }

    /* Check that we are on UMTS */
    if (!(s_umts_rinfo)) {
        ALOGI("%s() 2G Network. Slow Dormancy!", __func__ );
        enqueueRILEventName(RIL_EVENT_QUEUE_NORMAL, pollFastDormancy, NULL,
                                        &SLOW_FAST_DORMANCY_POLL, NULL);
        return;
    }

    err = ifc_statistics(ril_iface, &rx_packets, &tx_packets);
    if (err == -1) {
        ALOGE("%s() Unable to read /proc/net/dev. FD disabled!", __func__);
        return;
    } else if (err == 1) {
        ALOGE("%s() Interface (%s) not found. FD disabled!", __func__, ril_iface);
        return;
    }

    if ((old_rx_packets == rx_packets) && (old_rx_packets == rx_packets)) {
        if (dormant == 0) {
            ALOGI("%s() Data Dormant (RX:%llu TX: %llu) Enter Fast Dormancy!",
                            __func__, rx_packets, tx_packets );
            err = at_send_command("AT*EFDORM");
            if (err != AT_NOERROR) {
                ALOGW("%s() Failed Fast Dormancy. FD disabled!", __func__);
                return;
            } else {
                dormant = 1;
            }
        }
/* else {
            ALOGI("%s() Data Still Dormant (RX:%llu TX: %llu) Fast Dormancy!",
                            __func__, rx_packets, tx_packets );
        }
*/
    } else {
        if (dormant == 1) {
            dormant = 0;
            ALOGI("%s() Data transfer (RX:%llu TX: %llu) Exit Fast Dormancy!",
                            __func__, rx_packets, tx_packets );
        }
/* else {
            ALOGI("%s() Data transfer (RX:%llu TX: %llu)",
                            __func__, rx_packets, tx_packets );
        }
*/
        old_rx_packets = rx_packets;
        old_tx_packets = tx_packets;
    }

    enqueueRILEventName(RIL_EVENT_QUEUE_NORMAL, pollFastDormancy, NULL,
                                    &NORMAL_FAST_DORMANCY_POLL, NULL);

}

/**
 * Poll +COPS? and return a success, or if the loop counter reaches
 * REPOLL_OPERATOR_SELECTED, return generic failure.
 */
static void pollOperatorSelected(void *params)
{
    int err = 0;
    int response = 0;
    char *line = NULL;
    ATResponse *atresponse = NULL;
    struct operatorPollParams *poll_params;
    RIL_Token t;

    assert(params != NULL);

    poll_params = (struct operatorPollParams *) params;
    t = poll_params->t;

    if (poll_params->loopcount >= REPOLL_OPERATOR_SELECTED)
        goto error;

    /* Only poll COPS? if we are in static state, to prevent waking a
       suspended device (and during boot while module not beeing
       registered to network yet).
    */
    if (((s_cs_status == E2REG_UNKNOWN) || (s_cs_status == E2REG_IN_PROGRESS) ||
        (s_cs_status == E2REG_PENDING)) && ((s_ps_status == E2REG_UNKNOWN) ||
        ((s_ps_status == E2REG_IN_PROGRESS) || (s_ps_status == E2REG_PENDING)))) {
        poll_params->loopcount++;
        enqueueRILEventName(RIL_EVENT_QUEUE_PRIO, pollOperatorSelected,
                        poll_params, &TIMEVAL_OPERATOR_SELECT_POLL, NULL);
        return;
    }

    err = at_send_command_singleline("AT+COPS?", "+COPS:", &atresponse);
    if (err != AT_NOERROR)
        goto error;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&line, &response);
    if (err < 0)
        goto error;

    /* If we don't get more than the COPS: {0-4} we are not registered.
       Loop and try again. */
    if (!at_tok_hasmore(&line)) {
        switch (s_registrationDeniedReason) {
        case IMSI_UNKNOWN_IN_HLR: /* fall through */
        case ILLEGAL_ME:
            RIL_onRequestComplete(t, RIL_E_ILLEGAL_SIM_OR_ME, NULL, 0);
            free(poll_params);
            break;
        default:
            poll_params->loopcount++;
            enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, pollOperatorSelected,
                            poll_params, &TIMEVAL_OPERATOR_SELECT_POLL);
        }
    } else {
        /* We got operator, throw a success! */
        RIL_onRequestComplete(t, RIL_E_SUCCESS, NULL, 0);
        free(poll_params);
    }

    at_response_free(atresponse);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    free(poll_params);
    at_response_free(atresponse);
    return;
}

/**
 * Convert UCS2 hex coded string to UTF-8 coded string.
 *
 * E.g. "004100420043" -> "ABC"
 *
 * Note: Not valid for values corresponding to > 0x7f
 */
static char *convertUcs2ToUtf8(const char *ucs)
{
    int len, cnt;
    int idx, j;
    char *utf8Str;

    if (!ucs)
        return NULL;
    else
        len = strlen(ucs) / 4;

    if (!(utf8Str = malloc(len + 1)))
        return NULL;
    for (idx = 0, j = 0; idx < len; idx++) {
        char temp[5];
        int res;
        strncpy(temp, &ucs[j], 4);
        temp[4] = '\0';
        cnt = sscanf(temp, "%x", &res);
        if (cnt == 0 || cnt == EOF) {
            free(utf8Str);
            return NULL;
        }
        sprintf(&utf8Str[idx], "%c", res);
        j += 4;
    }
    utf8Str[idx] = '\0';
    return utf8Str;
}

/**
 * Converts an AT response string including UCS-2 formatted strings to a
 * corresponding AT response with the strings in UTF-8 format.
 *
 * Typical usage is when receiving an unsolicited response while UCS-2
 * format is temporarily used.
  */
static char* convertResponseToUtf8(const char *mbmargs){
    const char *forward, *back;
    char *output = NULL;
    char *str, *utf8;
    if(!(output = malloc(strlen(mbmargs)))) {
        ALOGE("%s() Failed to allocate memory", __func__);
        return NULL;
    }
    output[0] = '\0';
    forward = back = mbmargs;

    for (;;) {
        /* take anything before the " and put it into output and move back and forward inside the string*/
        if (!(forward = strstr(forward, "\"")))
            break;
        if (!(str = strndup(back, forward-back))) {
            ALOGE("%s() Failed to allocate memory", __func__);
            free(output);
            return NULL;
        }
        sprintf(output, "%s%s", output, str);
        free(str);
        forward++;
        back = forward;

        /* take everything inside the ucs2 string (without the "") and convert it and put the utf8 in output */
        if (!(forward = strstr(forward, "\""))) {
            free(output);
            ALOGE("%s() Bad ucs2 message, couldn't parse it:%s", __func__, mbmargs);
            return NULL;
        }
        /* The case when we have "" */
        if (back == forward){
            sprintf(output, "%s\"\"", output);
            forward++;
            back = forward;
            continue;
        }
        if (!(str = strndup(back, forward-back))) {
            free(output);
            ALOGE("%s() Failed to allocate memory", __func__);
            return NULL;
        }
        if (!(utf8 = convertUcs2ToUtf8(str))) {
            free(str);
            ALOGE("%s() Failed to allocate memory", __func__);
            free(output);
            return NULL;
        }
        sprintf(output, "%s\"%s\"", output, utf8);
        free(str);
        free(utf8);
        forward++;
        back = forward;
    }
    output = realloc(output, strlen(output) + 1);
    return output;
}

/**
 * RIL_UNSOL_NITZ_TIME_RECEIVED
 *
 * Called when radio has received a NITZ time message.
 *
 * "data" is const char * pointing to NITZ time string
 *
 */
void onNetworkTimeReceived(const char *s)
{
    /* Special handling of DST for Android framework
       Module does not include DST correction in NITZ,
       but Android expects it */

    char *line, *tok, *response, *time, *timestamp, *ucs = NULL;
    int tz, dst;

    if (!strstr(s,"/")) {
        ALOGI("%s() Bad format, converting string from ucs2: %s", __func__, s);
        ucs = convertResponseToUtf8(s);
        if (NULL == ucs) {
            ALOGE("%s() Failed converting string from ucs2", __func__);
            return;
        }
        s = (const char *)ucs;
    }

    tok = line = strdup(s);
    if (NULL == tok) {
        ALOGE("%s() Failed to allocate memory", __func__);
        free(ucs);
        return;
    }

    at_tok_start(&tok);

    ALOGD("%s() Got nitz: %s", __func__, s);
    if (at_tok_nextint(&tok, &tz) != 0)
        ALOGE("%s() Failed to parse NITZ tz %s", __func__, s);
    else if (at_tok_nextstr(&tok, &time) != 0)
        ALOGE("%s() Failed to parse NITZ time %s", __func__, s);
    else if (at_tok_nextstr(&tok, &timestamp) != 0)
        ALOGE("%s() Failed to parse NITZ timestamp %s", __func__, s);
    else {
        if (at_tok_nextint(&tok, &dst) != 0) {
            dst = 0;
            ALOGE("%s() Failed to parse NITZ dst, fallbacking to dst=0 %s",
             __func__, s);
        }
        if (!(asprintf(&response, "%s%+03d,%02d", time + 2, tz + (dst * 4), dst))) {
            free(line);
            ALOGE("%s() Failed to allocate string", __func__);
            free(ucs);
            return;
        }

        if (strncmp(response, last_nitz_time, strlen(response)) != 0) {
            RIL_onUnsolicitedResponse(RIL_UNSOL_NITZ_TIME_RECEIVED,
                                      response, sizeof(char *));
            /* If we're in screen state off, we have disabled CREG, but the ETZV
               will catch those few cases. So we send network state changed as
               well on NITZ. */
            if (!getScreenState())
                RIL_onUnsolicitedResponse(RIL_UNSOL_RESPONSE_VOICE_NETWORK_STATE_CHANGED,
                                          NULL, 0);
            strncpy(last_nitz_time, response, strlen(response));
            enqueueRILEvent(RIL_EVENT_QUEUE_NORMAL, sendTime,
                            NULL, NULL);
        } else
            ALOGD("%s() Discarding NITZ since it hasn't changed since last update",
             __func__);

        free(response);
    }

    free(ucs);
    free(line);
}

int getSignalStrength(RIL_SignalStrength_v6 *signalStrength){
    ATResponse *atresponse = NULL;
    int err;
    char *line;
    int ber;
    int rssi;

    memset(signalStrength, 0, sizeof(RIL_SignalStrength_v6));

    signalStrength->LTE_SignalStrength.signalStrength = -1;
    signalStrength->LTE_SignalStrength.rsrp = -1;
    signalStrength->LTE_SignalStrength.rsrq = -1;
    signalStrength->LTE_SignalStrength.rssnr = -1;
    signalStrength->LTE_SignalStrength.cqi = -1;

    err = at_send_command_singleline("AT+CSQ", "+CSQ:", &atresponse);

    if (err != AT_NOERROR)
        goto cind;
    
    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto cind;

    err = at_tok_nextint(&line,&rssi);
    if (err < 0)
        goto cind;
    signalStrength->GW_SignalStrength.signalStrength = rssi;

    err = at_tok_nextint(&line, &ber);
    if (err < 0)
        goto cind;
    signalStrength->GW_SignalStrength.bitErrorRate = ber;

    at_response_free(atresponse);
    atresponse = NULL;
    /*
     * If we get 99 as signal strength. Try AT+CIND to give
     * some indication on what signal strength we got.
     *
     * Android calculates rssi and dBm values from this value, so the dBm
     * value presented in android will be wrong, but this is an error on
     * android's end.
     */
    if (rssi == 99) {
cind:
        at_response_free(atresponse);
        atresponse = NULL;

        err = at_send_command_singleline("AT+CIND?", "+CIND:", &atresponse);
        if (err != AT_NOERROR)
            goto error;

        line = atresponse->p_intermediates->line;

        err = at_tok_start(&line);
        if (err < 0)
            goto error;

        /* discard the first value */
        err = at_tok_nextint(&line,
                             &signalStrength->GW_SignalStrength.signalStrength);
        if (err < 0)
            goto error;

        err = at_tok_nextint(&line,
                             &signalStrength->GW_SignalStrength.signalStrength);
        if (err < 0)
            goto error;

        signalStrength->GW_SignalStrength.bitErrorRate = 99;

        /* Convert CIND value so Android understands it correctly */
        if (signalStrength->GW_SignalStrength.signalStrength > 0) {
            signalStrength->GW_SignalStrength.signalStrength *= 4;
            signalStrength->GW_SignalStrength.signalStrength--;
        }
    }

    at_response_free(atresponse);
    return 0;

error:
    at_response_free(atresponse);
    return -1;
}

/**
 * RIL_REQUEST_NEIGHBORINGCELL_IDS
 */
void requestNeighboringCellIDs(void *data, size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen;

    if ((s_cs_status != E2REG_REGISTERED) && (s_ps_status != E2REG_REGISTERED)) {
        No_NCIs(t);
        return;
    }
    if (s_gsm_rinfo)        /* GSM (GPRS,2G) */
        Get_GSM_NCIs(t);
    else if (s_umts_rinfo)  /* UTRAN (WCDMA/UMTS, 3G) */
        Get_WCDMA_NCIs(t);
    else
        No_NCIs(t);
    return;
}

/**
 * GSM Network (GPRS, 2G) Neighborhood Cell IDs
 */
void Get_GSM_NCIs(RIL_Token t)
{
    int err = 0;
    char *p = NULL;
    int n = 0;
    ATLine *tmp = NULL;
    ATResponse *gnci_resp = NULL;
    RIL_NeighboringCell *ptr_cells[MAX_NUM_NEIGHBOR_CELLS];

    err = at_send_command_multiline("AT*EGNCI", "*EGNCI:", &gnci_resp);
    if (err != AT_NOERROR) {
        No_NCIs(t);
        goto finally;
    }

    tmp = gnci_resp->p_intermediates;
    while (tmp) {
        if (n > MAX_NUM_NEIGHBOR_CELLS)
            goto error;
        p = tmp->line;
        if (*p == '*') {
            char *line = p;
            char *plmn = NULL;
            char *lac = NULL;
            char *cid = NULL;
            int arfcn = 0;
            int bsic = 0;
            int rxlvl = 0;
            int ilac = 0;
            int icid = 0;

            err = at_tok_start(&line);
            if (err < 0) goto error;
            /* PLMN */
            err = at_tok_nextstr(&line, &plmn);
            if (err < 0) goto error;
            /* LAC */
            err = at_tok_nextstr(&line, &lac);
            if (err < 0) goto error;
            /* CellID */
            err = at_tok_nextstr(&line, &cid);
            if (err < 0) goto error;
            /* ARFCN */
            err = at_tok_nextint(&line, &arfcn);
            if (err < 0) goto error;
            /* BSIC */
            err = at_tok_nextint(&line, &bsic);
            if (err < 0) goto error;
            /* RxLevel */
            err = at_tok_nextint(&line, &rxlvl);
            if (err < 0) goto error;

            /* process data for each cell */
            ptr_cells[n] = alloca(sizeof(RIL_NeighboringCell));
            ptr_cells[n]->rssi = rxlvl;
            ptr_cells[n]->cid = alloca(9 * sizeof(char));
            sscanf(lac,"%x",&ilac);
            sscanf(cid,"%x",&icid);
            sprintf(ptr_cells[n]->cid, "%08x", ((ilac << 16) + icid));
            n++;
        }
        tmp = tmp->p_next;
    }

    RIL_onRequestComplete(t, RIL_E_SUCCESS, ptr_cells,
                          n * sizeof(RIL_NeighboringCell *));

finally:
    at_response_free(gnci_resp);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    goto finally;
}

/**
 * WCDMA Network (UTMS, 3G) Neighborhood Cell IDs
 */
void Get_WCDMA_NCIs(RIL_Token t)
{
    int err = 0;
    char *p = NULL;
    int n = 0;
    ATLine *tmp = NULL;
    ATResponse *wnci_resp = NULL;
    RIL_NeighboringCell *ptr_cells[MAX_NUM_NEIGHBOR_CELLS];

    err = at_send_command_multiline("AT*EWNCI", "*EWNCI:", &wnci_resp);
    if (err != AT_NOERROR) {
        No_NCIs(t);
        goto finally;
    }

    tmp = wnci_resp->p_intermediates;
    while (tmp) {
        if (n > MAX_NUM_NEIGHBOR_CELLS)
            goto error;
        p = tmp->line;
        if (*p == '*') {
            char *line = p;
            int uarfcn = 0;
            int psc = 0;
            int rscp = 0;
            int ecno = 0;
            int pathloss = 0;

            err = at_tok_start(&line);
            if (err < 0) goto error;
            /* UARFCN */
            err = at_tok_nextint(&line, &uarfcn);
            if (err < 0) goto error;
            /* PSC */
            err = at_tok_nextint(&line, &psc);
            if (err < 0) goto error;
            /* RSCP */
            err = at_tok_nextint(&line, &rscp);
            if (err < 0) goto error;
            /* ECNO */
            err = at_tok_nextint(&line, &ecno);
            if (err < 0) goto error;
            /* PathLoss */
            err = at_tok_nextint(&line, &pathloss);
            if (err < 0) goto error;

            /* process data for each cell */
            ptr_cells[n] = alloca(sizeof(RIL_NeighboringCell));
            ptr_cells[n]->rssi = rscp;
            ptr_cells[n]->cid = alloca(9 * sizeof(char));
            sprintf(ptr_cells[n]->cid, "%08x", psc);
            n++;
        }
        tmp = tmp->p_next;
    }

    RIL_onRequestComplete(t, RIL_E_SUCCESS, ptr_cells,
                          n * sizeof(RIL_NeighboringCell *));

finally:
    at_response_free(wnci_resp);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    goto finally;
}

/**
 * Not registered or unknown network (NOT UTMS or 3G)
 * return UNKNOWN_RSSI and UNKNOWN_CID 
 */
void No_NCIs(RIL_Token t)
{
    int n = 0;

    RIL_NeighboringCell *ptr_cells[MAX_NUM_NEIGHBOR_CELLS];

    ptr_cells[n] = alloca(sizeof(RIL_NeighboringCell));
    ptr_cells[n]->rssi = 99;
    ptr_cells[n]->cid = alloca(9 * sizeof(char));
    sprintf(ptr_cells[n]->cid, "%08x", -1);

    RIL_onRequestComplete(t, RIL_E_SUCCESS, ptr_cells,
                          n * sizeof(RIL_NeighboringCell *));

    return;
}

/**
 * RIL_UNSOL_SIGNAL_STRENGTH
 *
 * Radio may report signal strength rather than have it polled.
 *
 * "data" is a const RIL_SignalStrength *
 */
void pollSignalStrength(void *arg)
{
    RIL_SignalStrength_v6 signalStrength;
    (void) arg;

    rssi_queue = 0;

    if (getSignalStrength(&signalStrength) < 0)
        ALOGE("%s() Polling the signal strength failed", __func__);
    else
        RIL_onUnsolicitedResponse(RIL_UNSOL_SIGNAL_STRENGTH,
                                  &signalStrength, sizeof(RIL_SignalStrength_v6));
}

void onSignalStrengthChanged(const char *s)
{
    (void) s;

    if (rssi_queue == 0) {
        rssi_queue++;
        enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, pollSignalStrength, NULL, NULL);
    }
}

void onRegistrationStatusChanged(const char *s)
{
    char *line = NULL, *ptr = NULL;
    int *stat_ptr, *lac_ptr, *cid_ptr, *act_ptr = NULL;
    int commas = 0, update = 0;
    int skip, tmp, err;
    int creg_stat = 4, creg_lac = -1, creg_cid = -1, creg_act = -1;
    int cgreg_stat = 4, cgreg_lac = -1, cgreg_cid = -1, cgreg_act = -1;

    ptr = line = strdup(s);
    if (line == NULL) {
        ALOGE("%s() Failed to allocate memory", __func__);
        return;
    }

    at_tok_start(&line);

    if (strStartsWith(s, "+CREG:")) {
        stat_ptr = &creg_stat;
        lac_ptr = &creg_lac;
        cid_ptr = &creg_cid;
        act_ptr = &creg_act;
    } else {
        stat_ptr = &cgreg_stat;
        lac_ptr = &cgreg_lac;
        cid_ptr = &cgreg_cid;
        act_ptr = &cgreg_act;
    }

    /* Count number of commas */
    err = at_tok_charcounter(line, ',', &commas);
    if (err < 0) {
        ALOGE("%s() at_tok_charcounter failed", __func__);
        goto error;
    }

    switch (commas) {
    case 0:                    /* +xxREG: <stat> */
        err = at_tok_nextint(&line, stat_ptr);
        if (err < 0) goto error;
        break;

    case 1:                    /* +xxREG: <n>, <stat> */
        err = at_tok_nextint(&line, &skip);
        if (err < 0) goto error;
        err = at_tok_nextint(&line, stat_ptr);
        if (err < 0) goto error;
        break;

    case 2:                    /* +xxREG: <stat>, <lac>, <cid> */
        err = at_tok_nextint(&line, stat_ptr);
        if (err < 0) goto error;
        err = at_tok_nexthexint(&line, lac_ptr);
        if (err < 0) goto error;
        err = at_tok_nexthexint(&line, cid_ptr);
        if (err < 0) goto error;
        break;

    case 3:                    /* +xxREG: <n>, <stat>, <lac>, <cid> */
                               /* +xxREG: <stat>, <lac>, <cid>, <AcT> */
        err = at_tok_nextint(&line, &tmp);
        if (err < 0) goto error;

        /* We need to check if the second parameter is <lac> */
        if (*(line) == '"') {
            *stat_ptr = tmp; /* <stat> */
            err = at_tok_nexthexint(&line, lac_ptr); /* <lac> */
            if (err < 0) goto error;
            err = at_tok_nexthexint(&line, cid_ptr); /* <cid> */
            if (err < 0) goto error;
            err = at_tok_nextint(&line, act_ptr); /* <AcT> */
        } else {
            err = at_tok_nextint(&line, stat_ptr); /* <stat> */
           if (err < 0) goto error;
            err = at_tok_nexthexint(&line, lac_ptr); /* <lac> */
            if (err < 0) goto error;
            err = at_tok_nexthexint(&line, cid_ptr); /* <cid> */
            if (err < 0) goto error;
        }
        break;

    case 4:                    /* +xxREG: <n>, <stat>, <lac>, <cid>, <AcT> */
        err = at_tok_nextint(&line, &skip); /* <n> */
        if (err < 0) goto error;
        err = at_tok_nextint(&line, stat_ptr); /* <stat> */
        if (err < 0) goto error;
        err = at_tok_nexthexint(&line, lac_ptr); /* <lac> */
        if (err < 0) goto error;
        err = at_tok_nexthexint(&line, cid_ptr); /* <cid> */
        if (err < 0) goto error;
        err = at_tok_nextint(&line, act_ptr); /* <AcT> */
        break;

    default:
        ALOGE("%s() Invalid input", __func__);
        goto error;
    }


    /* Reduce the amount of unsolicited sent to the framework
       LAC and CID will be the same in both domains */
    if (strStartsWith(s, "+CREG:")) {
        if (s_creg_stat != creg_stat) {
            update = 1;
            s_creg_stat = creg_stat;
        }
        if (s_creg_lac != creg_lac) {
            if (s_cgreg_lac != creg_lac)
                update = 1;
            s_creg_lac = creg_lac;
        }
        if (s_creg_cid != creg_cid) {
            if (s_cgreg_cid != creg_cid)
                update = 1;
            s_creg_cid = creg_cid;
        }
    } else {
        if (s_cgreg_stat != cgreg_stat) {
            update = 1;
            s_cgreg_stat = cgreg_stat;
        }
        if (s_cgreg_lac != cgreg_lac) {
            if (s_creg_lac != cgreg_lac)
                update = 1;
            s_cgreg_lac = cgreg_lac;
        }
        if (s_cgreg_cid != cgreg_cid) {
            if (s_creg_cid != cgreg_cid)
                update = 1;
            s_cgreg_cid = cgreg_cid;
        }
        if (s_cgreg_act != cgreg_act) {
            update = 1;
            s_cgreg_act = cgreg_act;
        }
    }

    if (update) {
        s_reg_change = 1;
        RIL_onUnsolicitedResponse(RIL_UNSOL_RESPONSE_VOICE_NETWORK_STATE_CHANGED,
                                  NULL, 0);
    } else
        ALOGW("%s() Skipping unsolicited response since no change in state", __func__);

finally:
    free(ptr);
    return;

error:
    ALOGE("%s() Unable to parse (%s)", __func__, s);
    goto finally;
}

void onNetworkCapabilityChanged(const char *s)
{
    int err;
    int skip;
    char *line = NULL, *tok = NULL;
    static int old_gsm_rinfo = -1, old_umts_rinfo = -1;

    s_gsm_rinfo = s_umts_rinfo = 0;

    tok = line = strdup(s);
    if (tok == NULL)
        goto error;

    at_tok_start(&tok);

    err = at_tok_nextint(&tok, &skip);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&tok, &s_gsm_rinfo);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&tok, &s_umts_rinfo);
    if (err < 0)
        goto error;

    if ((old_gsm_rinfo != s_gsm_rinfo) || (old_umts_rinfo != s_umts_rinfo)) {
        old_gsm_rinfo = s_gsm_rinfo;
        old_umts_rinfo = s_umts_rinfo;
        /* No need to update when screen is off */
        if (getScreenState())
            RIL_onUnsolicitedResponse(RIL_UNSOL_RESPONSE_VOICE_NETWORK_STATE_CHANGED,
                                      NULL, 0);
    } else
        ALOGW("%s() Skipping unsolicited response since no change in state", __func__);

error:
    free(line);
}

void onNetworkStatusChanged(const char *s)
{
    int err;
    int skip;
    int resp;
    char *line = NULL, *tok = NULL;
    static int old_resp = -1;

    s_cs_status = s_ps_status = E2REG_UNKNOWN;
    tok = line = strdup(s);
    if (tok == NULL)
        goto error;

    at_tok_start(&tok);

    err = at_tok_nextint(&tok, &skip);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&tok, &s_cs_status);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&tok, &s_ps_status);
    if (err < 0)
        goto error;

    resp = RIL_RESTRICTED_STATE_NONE;

    switch (s_cs_status) {
        case E2REG_ACCESS_CLASS_BARRED:
        case E2REG_NO_ALLOWABLE_PLMN:
        case E2REG_PLMN_NOT_ALLOWED:
        case E2REG_LA_NOT_ALLOWED:
        case E2REG_ROAMING_NOT_ALLOWED:
        case E2REG_NO_SUITABLE_CELLS:
        case E2REG_INVALID_SIM_AUTH:
        case E2REG_INVALID_SIM_CONTENT:
        case E2REG_INVALID_SIM_LOCKED:
        case E2REG_INVALID_SIM_IMSI:
        case E2REG_INVALID_SIM_ILLEGAL_MS:
        case E2REG_INVALID_SIM_ILLEGAL_ME:
        case E2REG_INVALID_SIM_NO_GPRS:
            resp |= RIL_RESTRICTED_STATE_CS_ALL;
            break;
        default:
            break;
    }

    switch (s_ps_status) {
        case E2REG_ACCESS_CLASS_BARRED:
        case E2REG_NO_ALLOWABLE_PLMN:
        case E2REG_PLMN_NOT_ALLOWED:
        case E2REG_LA_NOT_ALLOWED:
        case E2REG_ROAMING_NOT_ALLOWED:
        case E2REG_PS_ONLY_GPRS_NOT_ALLOWED:
        case E2REG_NO_SUITABLE_CELLS:
        case E2REG_INVALID_SIM_AUTH:
        case E2REG_INVALID_SIM_CONTENT:
        case E2REG_INVALID_SIM_LOCKED:
        case E2REG_INVALID_SIM_IMSI:
        case E2REG_INVALID_SIM_ILLEGAL_MS:
        case E2REG_INVALID_SIM_ILLEGAL_ME:
        case E2REG_PS_ONLY_INVALID_SIM_GPRS:
        case E2REG_INVALID_SIM_NO_GPRS:
            resp |= RIL_RESTRICTED_STATE_PS_ALL;
            break;
        default:
            break;
    }

    if (old_resp != resp) {
        RIL_onUnsolicitedResponse(RIL_UNSOL_RESTRICTED_STATE_CHANGED,
                                  &resp, sizeof(int *));
        old_resp = resp;
    } else
        ALOGW("%s() Skipping unsolicited response since no change in state", __func__);

    /* If registered, poll signal strength for faster update of signal bar */
    if ((s_cs_status == E2REG_REGISTERED) || (s_ps_status == E2REG_REGISTERED)) {
        if (getScreenState())
		enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, pollSignalStrength, (void *)-1, NULL);
        /* Make sure registration state is updated when screen is off */
        if (!getScreenState())
            RIL_onUnsolicitedResponse(RIL_UNSOL_RESPONSE_VOICE_NETWORK_STATE_CHANGED,
                                      NULL, 0);
    }

error:
    free(line);
}

/**
 * RIL_REQUEST_SET_NETWORK_SELECTION_AUTOMATIC
 *
 * Specify that the network should be selected automatically.
*/
void requestSetNetworkSelectionAutomatic(void *data, size_t datalen,
                                         RIL_Token t)
{
    (void) data; (void) datalen;
    int err = 0;
    ATResponse *atresponse = NULL;
    int mode = 0;
    int skip;
    char *line;
    char *operator = NULL;
    struct operatorPollParams *poll_params = NULL;

    poll_params = malloc(sizeof(struct operatorPollParams));
    if (NULL == poll_params)
        goto error;

    /* First check if we are already scanning or in manual mode */
    err = at_send_command_singleline("AT+COPS=3,2;+COPS?", "+COPS:", &atresponse);
    if (err != AT_NOERROR)
        goto error;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    /* Read network selection mode */
    err = at_tok_nextint(&line, &mode);
    if (err < 0)
        goto error;

    s_cops_mode = mode;

    /* If we're unregistered, we may just get
       a "+COPS: 0" response. */
    if (!at_tok_hasmore(&line)) {
        if (mode == 1) {
            ALOGD("%s() Changing manual to automatic network mode", __func__);
            goto do_auto;
        } else
            goto check_reg;
    }

    err = at_tok_nextint(&line, &skip);
    if (err < 0)
        goto error;

    /* A "+COPS: 0, n" response is also possible. */
    if (!at_tok_hasmore(&line)) {
        if (mode == 1) {
            ALOGD("%s() Changing manual to automatic network mode", __func__);
            goto do_auto;
        } else
            goto check_reg;
    }

    /* Read numeric operator */
    err = at_tok_nextstr(&line, &operator);
    if (err < 0)
        goto error;

    /* If operator is found then do a new scan,
       else let it continue the already pending scan */
    if (operator && strlen(operator) == 0) {
        if (mode == 1) {
            ALOGD("%s() Changing manual to automatic network mode", __func__);
            goto do_auto;
        } else
            goto check_reg;
    }

    /* Operator found */
    if (mode == 1) {
        ALOGD("%s() Changing manual to automatic network mode", __func__);
        goto do_auto;
    } else {
        ALOGD("%s() Already in automatic mode with known operator, trigger a new network scan",
	    __func__);
        goto do_auto;
    }

    /* Check if module is scanning,
       if not then trigger a rescan */
check_reg:
    at_response_free(atresponse);
    atresponse = NULL;

    /* Check CS domain first */
    err = at_send_command_singleline("AT+CREG?", "+CREG:", &atresponse);
    if (err != AT_NOERROR)
        goto error;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    /* Read registration unsolicited mode */
    err = at_tok_nextint(&line, &mode);
    if (err < 0)
        goto error;

    /* Read registration status */
    err = at_tok_nextint(&line, &mode);
    if (err < 0)
        goto error;

    s_creg_stat = mode;

    /* If scanning has stopped, then perform a new scan */
    if (mode == 0) {
        ALOGD("%s() Already in automatic mode, but not currently scanning on CS,"
	     "trigger a new network scan", __func__);
        goto do_auto;
    }

    /* Now check PS domain */
    at_response_free(atresponse);
    atresponse = NULL;
    err = at_send_command_singleline("AT+CGREG?", "+CGREG:", &atresponse);
    if (err != AT_NOERROR)
        goto error;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    /* Read registration unsolicited mode */
    err = at_tok_nextint(&line, &mode);
    if (err < 0)
        goto error;

    /* Read registration status */
    err = at_tok_nextint(&line, &mode);
    if (err < 0)
        goto error;

    s_cgreg_stat = mode;

    /* If scanning has stopped, then perform a new scan */
    if (mode == 0) {
        ALOGD("%s() Already in automatic mode, but not currently scanning on PS,"
	     "trigger a new network scan", __func__);
        goto do_auto;
    }
    else
    {
        ALOGD("%s() Already in automatic mode and scanning", __func__);
        goto finish_scan;
    }

do_auto:
    at_response_free(atresponse);
    atresponse = NULL;

    /* This command does two things, one it sets automatic mode,
       two it starts a new network scan! */
    err = at_send_command("AT+COPS=0");
    if (err != AT_NOERROR)
        goto error;

    s_cops_mode = 0;

finish_scan:

    at_response_free(atresponse);
    atresponse = NULL;

    poll_params->loopcount = 0;
    poll_params->t = t;

    enqueueRILEvent(RIL_EVENT_QUEUE_NORMAL, pollOperatorSelected,
                    poll_params, &TIMEVAL_OPERATOR_SELECT_POLL);

    return;

error:
    free(poll_params);
    at_response_free(atresponse);
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    return;
}

/**
 * RIL_REQUEST_SET_NETWORK_SELECTION_MANUAL
 *
 * Manually select a specified network.
 *
 * The radio baseband/RIL implementation is expected to fall back to
 * automatic selection mode if the manually selected network should go
 * out of range in the future.
 */
void requestSetNetworkSelectionManual(void *data, size_t datalen,
                                      RIL_Token t)
{
    /*
     * AT+COPS=[<mode>[,<format>[,<oper>[,<AcT>]]]]
     *    <mode>   = 4 = Manual (<oper> field shall be present and AcT optionally) with fallback to automatic if manual fails.
     *    <format> = 2 = Numeric <oper>, the number has structure:
     *                   (country code digit 3)(country code digit 2)(country code digit 1)
     *                   (network code digit 2)(network code digit 1)
     */

    (void) datalen;
    int err = 0;
    const char *mccMnc = (const char *) data;

    /* Check inparameter. */
    if (mccMnc == NULL)
        goto error;

    /* Increase the AT command timeout for this operation */
    at_set_timeout_msec(1000 * 60 * 6);

    /* Build and send command. */
    err = at_send_command("AT+COPS=1,2,\"%s\"", mccMnc);

    /* Restore default AT command timeout */
    at_set_timeout_msec(1000 * 30);

    if (err != AT_NOERROR)
        goto error;

    s_cops_mode = 1;

    RIL_onRequestComplete(t, RIL_E_SUCCESS, NULL, 0);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
}

/**
 * RIL_REQUEST_QUERY_AVAILABLE_NETWORKS
 *
 * Scans for available networks.
*/
void requestQueryAvailableNetworks(void *data, size_t datalen, RIL_Token t)
{
    #define QUERY_NW_NUM_PARAMS 4

    /*
     * AT+COPS=?
     *   +COPS: [list of supported (<stat>,long alphanumeric <oper>
     *           ,short alphanumeric <oper>,numeric <oper>[,<AcT>])s]
     *          [,,(list of supported <mode>s),(list of supported <format>s)]
     *
     *   <stat>
     *     0 = unknown
     *     1 = available
     *     2 = current
     *     3 = forbidden
     */
    (void) data; (void) datalen;
    int err = 0;
    ATResponse *atresponse = NULL;
    ATResponse *cops_response = NULL;
    const char *statusTable[] =
        { "unknown", "available", "current", "forbidden" };
    char **responseArray = NULL;
    char *p;
    char *line = NULL;
    char *current = NULL;
    int current_act = -1;
    int skip;
    int n = 0;
    int i = 0;

    /* Increase the AT command timeout for this operation */
    at_set_timeout_msec(1000 * 60 * 6);

    /* Get available operators */
    err = at_send_command_multiline("AT+COPS=?", "+COPS:", &atresponse);

    /* Restore default AT command timeout */
    at_set_timeout_msec(1000 * 30);

    if (err != AT_NOERROR)
        goto error;

    p = atresponse->p_intermediates->line;

    /* count number of '('. */
    err = at_tok_charcounter(p, '(', &n);
    if (err < 0) goto error;

    /* Allocate array of strings, blocks of 4 strings. */
    responseArray = alloca(n * QUERY_NW_NUM_PARAMS * sizeof(char *));

    /* Get current operator and technology */
    err = at_send_command_singleline("AT+COPS=3,2;+COPS?", "+COPS:", &cops_response);
    if (err != AT_NOERROR)
        goto error;

    line = cops_response->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    /* Read and skip network selection mode */
    err = at_tok_nextint(&line, &skip);
    if (err < 0)
        goto no_current;

    /* Read and skip format */
    err = at_tok_nextint(&line, &skip);
    if (err < 0)
        goto no_current;

    /* Read current numeric operator */
    err = at_tok_nextstr(&line, &current);
    if (err < 0)
        goto no_current;

    /* Read act (Technology) */
    err = at_tok_nextint(&line, &current_act);

no_current:

    /* Loop and collect response information into the response array. */
    for (i = 0; i < n; i++) {
        int status = 0;
        line = NULL;
        char *s = NULL;
        char *longAlphaNumeric = NULL;
        char *shortAlphaNumeric = NULL;
        char *numeric = NULL;
        char *remaining = NULL;
        int act = -1;

        s = line = getFirstElementValue(p, "(", ")", &remaining);
        p = remaining;

        if (line == NULL) {
            ALOGE("%s() Null pointer while parsing COPS response."
	         "This should not happen.", __func__);
            break;
        }
        /* <stat> */
        err = at_tok_nextint(&line, &status);
        if (err < 0)
            goto error;

        /* Set home network as available network */
        if (status == 2)
            status = 1;

        /* long alphanumeric <oper> */
        err = at_tok_nextstr(&line, &longAlphaNumeric);
        if (err < 0)
            goto error;

        /* short alphanumeric <oper> */
        err = at_tok_nextstr(&line, &shortAlphaNumeric);
        if (err < 0)
            goto error;

        /* numeric <oper> */
        err = at_tok_nextstr(&line, &numeric);
        if (err < 0)
            goto error;

        /* Read act (Technology) */
        err = at_tok_nextint(&line, &act);
        if (err < 0)
            goto error;

        /* Find match for current operator in list */
        if ((strcmp(numeric, current) == 0) && (act == current_act))
            status = 2;

        responseArray[i * QUERY_NW_NUM_PARAMS + 0] = alloca(strlen(longAlphaNumeric) + 1);
        strcpy(responseArray[i * QUERY_NW_NUM_PARAMS + 0], longAlphaNumeric);

        responseArray[i * QUERY_NW_NUM_PARAMS + 1] = alloca(strlen(shortAlphaNumeric) + 1);
        strcpy(responseArray[i * QUERY_NW_NUM_PARAMS + 1], shortAlphaNumeric);

        responseArray[i * QUERY_NW_NUM_PARAMS + 2] = alloca(strlen(numeric) + 1);
        strcpy(responseArray[i * QUERY_NW_NUM_PARAMS + 2], numeric);

        free(s);

        /*
         * Check if modem returned an empty string, and fill it with MNC/MMC
         * if that's the case.
         */
        if (responseArray[i * QUERY_NW_NUM_PARAMS + 0] && strlen(responseArray[i * QUERY_NW_NUM_PARAMS + 0]) == 0) {
            responseArray[i * QUERY_NW_NUM_PARAMS + 0] = alloca(strlen(responseArray[i * QUERY_NW_NUM_PARAMS + 2]) + 1);
            strcpy(responseArray[i * QUERY_NW_NUM_PARAMS + 0], responseArray[i * QUERY_NW_NUM_PARAMS + 2]);
        }

        if (responseArray[i * QUERY_NW_NUM_PARAMS + 1] && strlen(responseArray[i * QUERY_NW_NUM_PARAMS + 1]) == 0) {
            responseArray[i * QUERY_NW_NUM_PARAMS + 1] = alloca(strlen(responseArray[i * QUERY_NW_NUM_PARAMS + 2]) + 1);
            strcpy(responseArray[i * QUERY_NW_NUM_PARAMS + 1], responseArray[i * QUERY_NW_NUM_PARAMS + 2]);
        }

       /* Add status */
        responseArray[i * QUERY_NW_NUM_PARAMS + 3] = alloca(strlen(statusTable[status]) + 1);
        sprintf(responseArray[i * QUERY_NW_NUM_PARAMS + 3], "%s", statusTable[status]);
    }

    RIL_onRequestComplete(t, RIL_E_SUCCESS, responseArray,
                          i * QUERY_NW_NUM_PARAMS * sizeof(char *));

finally:
    at_response_free(cops_response);
    at_response_free(atresponse);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    goto finally;
}

/*
 * get the preferred network type as set by Android
 */
int getPreferredNetworkType(void)
{
    return pref_net_type;
}

/**
 * RIL_REQUEST_SET_PREFERRED_NETWORK_TYPE
 *
 * Requests to set the preferred network type for searching and registering
 * (CS/PS domain, RAT, and operation mode).
 */
void requestSetPreferredNetworkType(void *data, size_t datalen,
                                    RIL_Token t)
{
    (void) datalen;
    int arg = 0;
    int err = 0;
    int rat;

    RIL_Errno errorno = RIL_E_GENERIC_FAILURE;

    rat = ((int *) data)[0];

    switch (rat) {
    case PREF_NET_TYPE_GSM_WCDMA_AUTO:
    case PREF_NET_TYPE_GSM_WCDMA:
        arg = PREF_NET_TYPE_3G;
        ALOGD("[%s] network type = auto", __FUNCTION__);
        break;
    case PREF_NET_TYPE_GSM_ONLY:
        arg = PREF_NET_TYPE_2G_ONLY;
        ALOGD("[%s] network type = 2g only", __FUNCTION__);
        break;
    case PREF_NET_TYPE_WCDMA:
        arg = PREF_NET_TYPE_3G_ONLY;
        ALOGD("[%s] network type = 3g only", __FUNCTION__);
        break;
    default:
        errorno = RIL_E_MODE_NOT_SUPPORTED;
        goto error;
    }

    pref_net_type = arg;

    err = at_send_command("AT+CFUN=%d", arg);
    if (err == AT_NOERROR) {
        RIL_onRequestComplete(t, RIL_E_SUCCESS, NULL, 0);
        return;
    }

error:
    RIL_onRequestComplete(t, errorno, NULL, 0);
}

/**
 * RIL_REQUEST_GET_PREFERRED_NETWORK_TYPE
 *
 * Query the preferred network type (CS/PS domain, RAT, and operation mode)
 * for searching and registering.
 */
void requestGetPreferredNetworkType(void *data, size_t datalen,
                                    RIL_Token t)
{
    (void) data; (void) datalen;
    int err = 0;
    int response = 0;
    int cfun;
    char *line;
    ATResponse *atresponse;

    err = at_send_command_singleline("AT+CFUN?", "+CFUN:", &atresponse);
    if (err != AT_NOERROR)
        goto error;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&line, &cfun);
    if (err < 0)
        goto error;

    if (cfun < 0 || cfun >= 7)
        goto error;

    switch (cfun) {
    case PREF_NET_TYPE_2G_ONLY:
        response = PREF_NET_TYPE_GSM_ONLY;
        break;
    case PREF_NET_TYPE_3G_ONLY:
        response = PREF_NET_TYPE_WCDMA;
        break;
    case PREF_NET_TYPE_3G:
        response = PREF_NET_TYPE_GSM_WCDMA_AUTO;
        break;
    default:
        response = PREF_NET_TYPE_GSM_WCDMA_AUTO;
        break;
    }

    RIL_onRequestComplete(t, RIL_E_SUCCESS, &response, sizeof(int));

finally:
    at_response_free(atresponse);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    goto finally;
}

/**
 * RIL_REQUEST_QUERY_NETWORK_SELECTION_MODE
 *
 * Query current network selectin mode.
 */
void requestQueryNetworkSelectionMode(void *data, size_t datalen,
                                      RIL_Token t)
{
    (void) data; (void) datalen;
    int err;
    ATResponse *atresponse = NULL;
    int response = s_cops_mode;
    char *line;

    if (s_cops_mode != -1)
        goto no_sim;

    err = at_send_command_singleline("AT+COPS?", "+COPS:", &atresponse);

    if (at_get_cme_error(err) == CME_SIM_NOT_INSERTED)
        goto no_sim;

    if (err != AT_NOERROR)
        goto error;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);

    if (err < 0)
        goto error;

    err = at_tok_nextint(&line, &response);

    if (err < 0)
        goto error;

    /*
     * Android accepts 0(automatic) and 1(manual).
     * Modem may return mode 4(Manual/automatic).
     * Convert it to 1(Manual) as android expects.
     */
    if (response == 4)
        response = 1;

no_sim:
    RIL_onRequestComplete(t, RIL_E_SUCCESS, &response, sizeof(int));

finally:
    at_response_free(atresponse);
    return;

error:
    ALOGE("%s() Must never return error when radio is on", __func__);
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    goto finally;
}

/**
 * RIL_REQUEST_SIGNAL_STRENGTH
 *
 * Requests current signal strength and bit error rate.
 *
 * Must succeed if radio is on.
 */
void requestSignalStrength(void *data, size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen;
    RIL_SignalStrength_v6 signalStrength;

    if (getSignalStrength(&signalStrength) < 0) {
        ALOGE("%s() Must never return an error when radio is on", __func__);
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    } else
        RIL_onRequestComplete(t, RIL_E_SUCCESS, &signalStrength,
                              sizeof(RIL_SignalStrength_v6));
}

/**
 * Convert CS detailedReason from modem to what Android expects.
 * Called in requestRegistrationState().
 */
static
CsReg_Deny_DetailReason convertCsRegistrationDeniedReason(int detailedReason)
{
    CsReg_Deny_DetailReason reason;

    switch (detailedReason) {
    case E2REG_NO_RESPONSE:
        reason = NETWORK_FAILURE;
        break;
    case E2REG_PLMN_NOT_ALLOWED:
    case E2REG_NO_ALLOWABLE_PLMN:
        reason = PLMN_NOT_ALLOWED;
        break;
    case E2REG_LA_NOT_ALLOWED:
        reason = LOCATION_AREA_NOT_ALLOWED;
        break;
    case E2REG_ROAMING_NOT_ALLOWED:
        reason = ROAMING_NOT_ALLOWED;
        break;
    case E2REG_NO_SUITABLE_CELLS:
        reason = NO_SUITABLE_CELL_IN_LOCATION_AREA;
        break;
    case E2REG_INVALID_SIM_AUTH:
    case E2REG_INVALID_SIM_CONTENT:
    case E2REG_INVALID_SIM_LOCKED:
    case E2REG_INVALID_SIM_NO_GPRS:
        reason = AUTHENTICATION_FAILURE;
        break;
    case E2REG_INVALID_SIM_IMSI:
        reason = IMSI_UNKNOWN_IN_HLR;
        break;
    case E2REG_INVALID_SIM_ILLEGAL_MS:
        reason = ILLEGAL_MS;
        break;
    case E2REG_INVALID_SIM_ILLEGAL_ME:
        reason = ILLEGAL_ME;
        break;
    default:
        reason = GENERAL;
        break;
    }

    return reason;
}

/**
 * Convert PS detailedReason from modem to what Android expects.
 * Called in requestGprsRegistrationState().
 */
static
PsReg_Deny_DetailReason convertPsRegistrationDeniedReason(int detailedReason)
{
    PsReg_Deny_DetailReason reason;

    switch (detailedReason) {
    case E2REG_DETACHED:
        reason = IMPLICITLY_DETACHED;
        break;
    case E2REG_PS_ONLY_GPRS_NOT_ALLOWED:
    case E2REG_NO_SUITABLE_CELLS:
    case E2REG_NO_ALLOWABLE_PLMN:
    case E2REG_PLMN_NOT_ALLOWED:
    case E2REG_LA_NOT_ALLOWED:
    case E2REG_ROAMING_NOT_ALLOWED:
        reason = GPRS_NOT_ALLOWED_PLMN;
        break;
    case E2REG_INVALID_SIM_ILLEGAL_MS:
        reason = MS_IDENTITY_UNKNOWN;
        break;
    case E2REG_PS_ONLY_INVALID_SIM_GPRS:
        reason = GPRS_NOT_ALLOWED;
        break;
    case E2REG_INVALID_SIM_NO_GPRS:
    case E2REG_INVALID_SIM_AUTH:
    case E2REG_INVALID_SIM_CONTENT:
    case E2REG_INVALID_SIM_LOCKED:
    case E2REG_INVALID_SIM_IMSI:
    case E2REG_INVALID_SIM_ILLEGAL_ME:
        reason = GPRS_NON_GPRS_NOT_ALLOWED;
        break;
    default:
        reason = GENERAL;
        break;
    }

    return reason;
}

char *getNetworkType(int def)
{
    int network = def;
    int err, skip;
    static int ul, dl;
    int networkType;
    char *line;
    ATResponse *p_response;
    static int old_umts_rinfo = -1;

    if (s_umts_rinfo > ERINFO_UMTS_NO_UMTS_HSDPA &&
        getE2napState() == E2NAP_STATE_CONNECTED &&
        old_umts_rinfo != s_umts_rinfo) {

        old_umts_rinfo = s_umts_rinfo;
        err = at_send_command_singleline("AT+CGEQNEG=%d", "+CGEQNEG:", &p_response, RIL_CID_IP);

        if (err != AT_NOERROR)
            ALOGE("%s() Allocation for, or sending, CGEQNEG failed."
	         "Using default value specified by calling function", __func__);
        else {
            line = p_response->p_intermediates->line;
            err = at_tok_start(&line);
            if (err < 0)
                goto finally;

            err = at_tok_nextint(&line, &skip);
            if (err < 0)
                goto finally;

            err = at_tok_nextint(&line, &skip);
            if (err < 0)
                goto finally;

            err = at_tok_nextint(&line, &ul);
            if (err < 0)
                goto finally;

            err = at_tok_nextint(&line, &dl);
            if (err < 0)
                goto finally;

            at_response_free(p_response);
            ALOGI("Max speed %i/%i, UL/DL", ul, dl);
        }
    }
    if (s_umts_rinfo > ERINFO_UMTS_NO_UMTS_HSDPA) {
        network = CGREG_ACT_UTRAN;
        if (dl > 384)
            network = CGREG_ACT_UTRAN_HSDPA;
        if (ul > 384) {
            if (s_umts_rinfo == ERINFO_UMTS_HSPA_EVOL)
                network = CGREG_ACT_UTRAN_HSPAP;
            else
                network = CGREG_ACT_UTRAN_HSUPA_HSDPA;
        }
    }
    else if (s_gsm_rinfo) {
        ALOGD("%s() Using 2G info: %d", __func__, s_gsm_rinfo);
        if (s_gsm_rinfo == 1)
            network = CGREG_ACT_GSM;
        else
            network = CGREG_ACT_GSM_EGPRS;
    }

    switch (network) {
    case CGREG_ACT_GSM:
        networkType = RADIO_TECH_GPRS;
        break;
    case CGREG_ACT_UTRAN:
        networkType = RADIO_TECH_UMTS;
        break;
    case CGREG_ACT_GSM_EGPRS:
        networkType = RADIO_TECH_EDGE;
        break;
    case CGREG_ACT_UTRAN_HSDPA:
        networkType = RADIO_TECH_HSDPA;
        break;
    case CGREG_ACT_UTRAN_HSUPA:
        networkType = RADIO_TECH_HSUPA;
        break;
    case CGREG_ACT_UTRAN_HSUPA_HSDPA:
        networkType = RADIO_TECH_HSPA;
        break;
    case CGREG_ACT_UTRAN_HSPAP:
        networkType = RADIO_TECH_HSPAP;
        break;
    default:
        networkType = RADIO_TECH_UNKNOWN;
        break;
    }
    char *resp;
    asprintf(&resp, "%d", networkType);
    return resp;

finally:
    at_response_free(p_response);
    return NULL;
}
/**
 * RIL_REQUEST_DATA_REGISTRATION_STATE
 *
 * Request current GPRS registration state.
 */
void requestGprsRegistrationState(int request, void *data,
                              size_t datalen, RIL_Token t)
{
    (void)request, (void)data, (void)datalen;
    int err = 0;
    const char resp_size = 6;
    int response[resp_size];
    char *responseStr[resp_size];
    ATResponse *cgreg_resp = NULL, *e2reg_resp = NULL;
    char *line, *p;
    int commas = 0;
    int skip, tmp;
    int ps_status = 0;
    int count = 3;
    int i;

    memset(responseStr, 0, sizeof(responseStr));
    memset(response, 0, sizeof(response));
    response[1] = -1;
    response[2] = -1;

    /* We only allow polling if screenstate is off, in such case
       CREG and CGREG unsolicited are disabled */
    getScreenStateLock();
    if (!getScreenState())
        (void)at_send_command("AT+CGREG=2"); /* Response not vital */
    else {
        response[0] = s_cgreg_stat;
        response[1] = s_cgreg_lac;
        response[2] = s_cgreg_cid;
        response[3] = s_cgreg_act;
        if (response[0] == CGREG_STAT_REG_DENIED)
            response[4] = convertPsRegistrationDeniedReason(s_ps_status);
        goto cached;
    }


    err = at_send_command_singleline("AT+CGREG?", "+CGREG: ", &cgreg_resp);

    if (at_get_cme_error(err) == CME_SIM_NOT_INSERTED)
        goto no_sim;

    if (err != AT_NOERROR)
        goto error;

    line = cgreg_resp->p_intermediates->line;
    err = at_tok_start(&line);
    if (err < 0)
        goto error;
    /*
     * The solicited version of the +CGREG response is
     * +CGREG: n, stat, [lac, cid [,<AcT>]]
     * and the unsolicited version is
     * +CGREG: stat, [lac, cid [,<AcT>]]
     * The <n> parameter is basically "is unsolicited creg on?"
     * which it should always be.
     *
     * Now we should normally get the solicited version here,
     * but the unsolicited version could have snuck in
     * so we have to handle both.
     *
     * Also since the LAC, CID and AcT are only reported when registered,
     * we can have 1, 2, 3, 4 or 5 arguments here.
     */
    /* Count number of commas */
    p = line;
    err = at_tok_charcounter(line, ',', &commas);
    if (err < 0) {
        ALOGE("%s() at_tok_charcounter failed", __func__);
        goto error;
    }

    switch (commas) {
    case 0:                    /* +CGREG: <stat> */
        err = at_tok_nextint(&line, &response[0]);
        if (err < 0) goto error;
        break;

    case 1:                    /* +CGREG: <n>, <stat> */
        err = at_tok_nextint(&line, &skip);
        if (err < 0) goto error;
        err = at_tok_nextint(&line, &response[0]);
        if (err < 0) goto error;
        break;

    case 2:                    /* +CGREG: <stat>, <lac>, <cid> */
        err = at_tok_nextint(&line, &response[0]);
        if (err < 0) goto error;
        err = at_tok_nexthexint(&line, &response[1]);
        if (err < 0) goto error;
        err = at_tok_nexthexint(&line, &response[2]);
        if (err < 0) goto error;
        break;

    case 3:                    /* +CGREG: <n>, <stat>, <lac>, <cid> */
                               /* +CGREG: <stat>, <lac>, <cid>, <AcT> */
        err = at_tok_nextint(&line, &tmp);
        if (err < 0) goto error;

        /* We need to check if the second parameter is <lac> */
        if (*(line) == '"') {
            response[0] = tmp; /* <stat> */
            err = at_tok_nexthexint(&line, &response[1]); /* <lac> */
            if (err < 0) goto error;
            err = at_tok_nexthexint(&line, &response[2]); /* <cid> */
            if (err < 0) goto error;
            err = at_tok_nextint(&line, &response[3]); /* <AcT> */
            if (err < 0) goto error;
            count = 4;
        } else {
            err = at_tok_nextint(&line, &response[0]); /* <stat> */
            if (err < 0) goto error;
            err = at_tok_nexthexint(&line, &response[1]); /* <lac> */
            if (err < 0) goto error;
            err = at_tok_nexthexint(&line, &response[2]); /* <cid> */
            if (err < 0) goto error;
        }
        break;

    case 4:                    /* +CGREG: <n>, <stat>, <lac>, <cid>, <AcT> */
        err = at_tok_nextint(&line, &skip); /* <n> */
        if (err < 0) goto error;
        err = at_tok_nextint(&line, &response[0]); /* <stat> */
        if (err < 0) goto error;
        err = at_tok_nexthexint(&line, &response[1]); /* <lac> */
        if (err < 0) goto error;
        err = at_tok_nexthexint(&line, &response[2]); /* <cid> */
        if (err < 0) goto error;
        err = at_tok_nextint(&line, &response[3]); /* <AcT> */
        if (err < 0) goto error;
        count = 4;
        break;

    default:
        ALOGE("%s() Invalid input", __func__);
        goto error;
    }

    if (response[0] == CGREG_STAT_REG_DENIED) {
        err = at_send_command_singleline("AT*E2REG?", "*E2REG:", &e2reg_resp);

        if (err != AT_NOERROR)
            goto error;

        line = e2reg_resp->p_intermediates->line;
        err = at_tok_start(&line);
        if (err < 0)
            goto error;

        err = at_tok_nextint(&line, &skip);
        if (err < 0)
            goto error;

        err = at_tok_nextint(&line, &skip);
        if (err < 0)
            goto error;

        err = at_tok_nextint(&line, &ps_status);
        if (err < 0)
            goto error;

        response[4] = convertPsRegistrationDeniedReason(ps_status);
    }

    if (s_cgreg_stat != response[0] ||
        s_cgreg_lac != response[1] ||
        s_cgreg_cid != response[2] ||
        s_cgreg_act != response[3]) {

        s_cgreg_stat = response[0];
        s_cgreg_lac = response[1];
        s_cgreg_cid = response[2];
        s_cgreg_act = response[3];
        s_reg_change = 1;
    }

cached:
    if (response[0] == CGREG_STAT_REG_HOME_NET ||
        response[0] == CGREG_STAT_ROAMING)
        responseStr[3] = getNetworkType(response[3]);

no_sim:
    /* Converting to stringlist for Android */
    asprintf(&responseStr[0], "%d", response[0]); /* state */

    if (response[1] >= 0)
        asprintf(&responseStr[1], "%04x", response[1]); /* LAC */
    else
        responseStr[1] = NULL;

    if (response[2] >= 0)
        asprintf(&responseStr[2], "%08x", response[2]); /* CID */
    else
        responseStr[2] = NULL;

    if (response[4] >= 0)
        err = asprintf(&responseStr[4], "%d", response[4]);
    else
        responseStr[4] = NULL;

    asprintf(&responseStr[5], "%d", 1);

    RIL_onRequestComplete(t, RIL_E_SUCCESS, responseStr, resp_size * sizeof(char *));

finally:
    if (!getScreenState())
        (void)at_send_command("AT+CGREG=0");

    releaseScreenStateLock(); /* Important! */

    for (i = 0; i < resp_size; i++)
        free(responseStr[i]);

    at_response_free(cgreg_resp);
    at_response_free(e2reg_resp);
    return;

error:
    ALOGE("%s Must never return an error when radio is on", __func__);
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    goto finally;
}

/**
 * RIL_REQUEST_VOICE_REGISTRATION_STATE
 *
 * Request current registration state.
 */
void requestRegistrationState(int request, void *data,
                              size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen, (void)request;
    int err = 0;
    const char resp_size = 15;
    int response[resp_size];
    char *responseStr[resp_size];
    ATResponse *creg_resp = NULL, *e2reg_resp = NULL;
    char *line;
    int commas = 0;
    int skip, cs_status = 0;
    int i;

    /* Setting default values in case values are not returned by AT command */
    for (i = 0; i < resp_size; i++)
        responseStr[i] = NULL;

    memset(response, 0, sizeof(response));

    /* IMPORTANT: Will take screen state lock here. Make sure to always call
                  releaseScreenStateLock BEFORE returning! */
    getScreenStateLock();
    if (!getScreenState())
        (void)at_send_command("AT+CREG=2"); /* Ignore the response, not VITAL. */
    else {
        response[0] = s_creg_stat;
        response[1] = s_creg_lac;
        response[2] = s_creg_cid;
        if (response[0] == CGREG_STAT_REG_DENIED)
            response[13] = convertCsRegistrationDeniedReason(s_cs_status);
        goto cached;
    }

    err = at_send_command_singleline("AT+CREG?", "+CREG:", &creg_resp);

    if (at_get_cme_error(err) == CME_SIM_NOT_INSERTED)
        goto no_sim;

    if (err != AT_NOERROR)
        goto error;

    line = creg_resp->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    /*
     * The solicited version of the CREG response is
     * +CREG: n, stat, [lac, cid]
     * and the unsolicited version is
     * +CREG: stat, [lac, cid]
     * The <n> parameter is basically "is unsolicited creg on?"
     * which it should always be.
     *
     * Now we should normally get the solicited version here,
     * but the unsolicited version could have snuck in
     * so we have to handle both.
     *
     * Also since the LAC and CID are only reported when registered,
     * we can have 1, 2, 3, or 4 arguments here.
     *
     * finally, a +CGREG: answer may have a fifth value that corresponds
     * to the network type, as in;
     *
     *   +CGREG: n, stat [,lac, cid [,networkType]]
     */

    /* Count number of commas */
    err = at_tok_charcounter(line, ',', &commas);

    if (err < 0)
        goto error;

    switch (commas) {
    case 0:                    /* +CREG: <stat> */
        err = at_tok_nextint(&line, &response[0]);
        if (err < 0)
            goto error;

        response[1] = -1;
        response[2] = -1;
        break;

    case 1:                    /* +CREG: <n>, <stat> */
        err = at_tok_nextint(&line, &skip);
        if (err < 0)
            goto error;

        err = at_tok_nextint(&line, &response[0]);
        if (err < 0)
            goto error;

        response[1] = -1;
        response[2] = -1;
        if (err < 0)
            goto error;
        break;
    case 2:                    /* +CREG: <stat>, <lac>, <cid> */
        err = at_tok_nextint(&line, &response[0]);
        if (err < 0)
            goto error;

        err = at_tok_nexthexint(&line, &response[1]);
        if (err < 0)
            goto error;

        err = at_tok_nexthexint(&line, &response[2]);
        if (err < 0)
            goto error;
        break;
    case 3:                    /* +CREG: <n>, <stat>, <lac>, <cid> */
    case 4:                    /* +CREG: <n>, <stat>, <lac>, <cid>, <?> */
        err = at_tok_nextint(&line, &skip);
        if (err < 0)
            goto error;

        err = at_tok_nextint(&line, &response[0]);
        if (err < 0)
            goto error;

        err = at_tok_nexthexint(&line, &response[1]);
        if (err < 0)
            goto error;

        err = at_tok_nexthexint(&line, &response[2]);
        if (err < 0)
            goto error;
        break;
    default:
        goto error;
    }

    s_registrationDeniedReason = DEFAULT_VALUE;

    if (response[0] == CGREG_STAT_REG_DENIED) {
        err = at_send_command_singleline("AT*E2REG?", "*E2REG:", &e2reg_resp);

        if (err != AT_NOERROR)
            goto error;

        line = e2reg_resp->p_intermediates->line;
        err = at_tok_start(&line);
        if (err < 0)
            goto error;

        err = at_tok_nextint(&line, &skip);
        if (err < 0)
            goto error;

        err = at_tok_nextint(&line, &cs_status);
        if (err < 0)
            goto error;

        response[13] = convertCsRegistrationDeniedReason(cs_status);
        s_registrationDeniedReason = response[13];
    }

    if (s_creg_stat != response[0] ||
        s_creg_lac != response[1] ||
        s_creg_cid != response[2]) {

        s_creg_stat = response[0];
        s_creg_lac = response[1];
        s_creg_cid = response[2];
        s_reg_change = 1;
    }

cached:
    if (response[0] == CGREG_STAT_REG_HOME_NET ||
        response[0] == CGREG_STAT_ROAMING)
        responseStr[3] = getNetworkType(0);

no_sim:
    err = asprintf(&responseStr[0], "%d", response[0]);
    if (err < 0)
            goto error;

    if (response[1] > 0)
        err = asprintf(&responseStr[1], "%04x", response[1]);
    if (err < 0)
        goto error;

    if (response[2] > 0)
        err = asprintf(&responseStr[2], "%08x", response[2]);
    if (err < 0)
        goto error;

    if (response[13] > 0)
        err = asprintf(&responseStr[13], "%d", response[13]);
    if (err < 0)
        goto error;

    RIL_onRequestComplete(t, RIL_E_SUCCESS, responseStr,
                          resp_size * sizeof(char *));

finally:
    if (!getScreenState())
        (void)at_send_command("AT+CREG=0");

    releaseScreenStateLock(); /* Important! */

    for (i = 0; i < resp_size; i++)
        free(responseStr[i]);

    at_response_free(creg_resp);
    at_response_free(e2reg_resp);
    return;

error:
    ALOGE("%s() Must never return an error when radio is on", __func__);
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    goto finally;
}

/**
 * RIL_REQUEST_OPERATOR
 *
 * Request current operator ONS or EONS.
 */
void requestOperator(void *data, size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen;
    int err;
    int i;
    int skip;
    ATLine *cursor;
    static const int num_resp_lines = 3;
    char *response[num_resp_lines];
    static char *old_response[3] = {NULL, NULL, NULL};
    ATResponse *atresponse = NULL;

    memset(response, 0, sizeof(response));

    if (!(s_creg_stat == CGREG_STAT_REG_HOME_NET ||
        s_creg_stat == CGREG_STAT_ROAMING ||
        s_cgreg_stat == CGREG_STAT_REG_HOME_NET ||
        s_cgreg_stat == CGREG_STAT_ROAMING))
        goto no_sim;

    if (!(s_reg_change)) {
        if (old_response[0] != NULL) {
            memcpy(response, old_response, sizeof(old_response));
            ALOGW("%s() Using buffered info since no change in state", __func__);
            goto no_sim;
        }
    }

    s_reg_change = 0;

    err = at_send_command_multiline
        ("AT+COPS=3,0;+COPS?;+COPS=3,1;+COPS?;+COPS=3,2;+COPS?", "+COPS:",
         &atresponse);

    if (at_get_cme_error(err) == CME_SIM_NOT_INSERTED)
        goto no_sim;

    if (err != AT_NOERROR)
        goto error;

    /* We expect 3 lines here:
     * +COPS: 0,0,"T - Mobile"
     * +COPS: 0,1,"TMO"
     * +COPS: 0,2,"310170"
     */
    for (i = 0, cursor = atresponse->p_intermediates;
         cursor != NULL && i < num_resp_lines;
         cursor = cursor->p_next, i++) {
        char *line = cursor->line;

        err = at_tok_start(&line);

        if (err < 0)
            goto error;

        err = at_tok_nextint(&line, &skip);

        if (err < 0)
            goto error;

        /* If we're unregistered, we may just get
           a "+COPS: 0" response. */
        if (!at_tok_hasmore(&line)) {
            response[i] = NULL;
            continue;
        }

        err = at_tok_nextint(&line, &skip);

        if (err < 0)
            goto error;

        /* A "+COPS: 0, n" response is also possible. */
        if (!at_tok_hasmore(&line)) {
            response[i] = NULL;
            continue;
        }

        err = at_tok_nextstr(&line, &(response[i]));

        if (err < 0)
            goto error;
    }

    if (i != num_resp_lines)
        goto error;

    /*
     * Check if modem returned an empty string, and fill it with MNC/MMC
     * if that's the case.
     */
    if (response[2] && response[0] && strlen(response[0]) == 0) {
        response[0] = alloca(strlen(response[2]) + 1);
        strcpy(response[0], response[2]);
    }

    if (response[2] && response[1] && strlen(response[1]) == 0) {
        response[1] = alloca(strlen(response[2]) + 1);
        strcpy(response[1], response[2]);
    }
    for (i = 0; i < num_resp_lines; i++) {
        if (old_response[i] != NULL) {
            free(old_response[i]);
            old_response[i] = NULL;
        }
        if (response[i] != NULL) {
            old_response[i] = strdup(response[i]);
        }
    }

no_sim:
    RIL_onRequestComplete(t, RIL_E_SUCCESS, response, sizeof(response));

finally:
    at_response_free(atresponse);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    goto finally;
}
           u300-ril-network.h                                                                                  0000644 0001750 0001750 00000004524 12316216523 014027  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#ifndef U300_RIL_NETWORK_H
#define U300_RIL_NETWORK_H 1

void onNetworkTimeReceived(const char *s);
void onSignalStrengthChanged(const char *s);
void onNetworkStatusChanged(const char *s);

void onRegistrationStatusChanged(const char *s);

void onNetworkCapabilityChanged(const char *s);

int getPreferredNetworkType(void);

void requestSetNetworkSelectionAutomatic(void *data, size_t datalen, RIL_Token t);
void requestSetNetworkSelectionManual(void *data, size_t datalen, RIL_Token t);
void requestQueryAvailableNetworks(void *data, size_t datalen, RIL_Token t);
void requestSetPreferredNetworkType(void *data, size_t datalen, RIL_Token t);
void requestGetPreferredNetworkType(void *data, size_t datalen, RIL_Token t);
void requestEnterNetworkDepersonalization(void *data, size_t datalen, RIL_Token t);
void requestQueryNetworkSelectionMode(void *data, size_t datalen, RIL_Token t);
void requestSignalStrength(void *data, size_t datalen, RIL_Token t); 
void requestRegistrationState(int request, void *data, size_t datalen, RIL_Token t);
void requestGprsRegistrationState(int request, void *data, size_t datalen, RIL_Token t);
void requestOperator(void *data, size_t datalen, RIL_Token t);
void requestRadioPower(void *data, size_t datalen, RIL_Token t);

void pollSignalStrength(void *bar);
void sendTime(void *p);

void requestNeighboringCellIDs(void *data, size_t datalen, RIL_Token t);
void Get_GSM_NCIs(RIL_Token t);
void Get_WCDMA_NCIs(RIL_Token t);
void No_NCIs(RIL_Token t);

void startPollFastDormancy(void);
#endif
                                                                                                                                                                            u300-ril-oem.c                                                                                      0000644 0001750 0001750 00000007251 12271742740 013116  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#include <stdio.h>
#include <telephony/ril.h>
#include "u300-ril.h"
#include "atchannel.h"
#include "at_tok.h"
#include "u300-ril-device.h"

#define LOG_TAG "RIL"
#include <utils/Log.h>

#if 0
/**
 * RIL_REQUEST_OEM_HOOK_RAW
 *
 * This request reserved for OEM-specific uses. It passes raw byte arrays
 * back and forth.
*/
void requestOEMHookRaw(void *data, size_t datalen, RIL_Token t)
{
    /* Echo back data */
    RIL_onRequestComplete(t, RIL_E_SUCCESS, data, datalen);
    return;
}
#endif

/**
 * RIL_REQUEST_OEM_HOOK_STRINGS
 *
 * This request reserved for OEM-specific uses. It passes strings
 * back and forth.
*/
void requestOEMHookStrings(void *data, size_t datalen, RIL_Token t)
{
    int i;
    const char **cur;
    ATResponse *atresponse = NULL;
    ATLine *atline;
    int linecount;
    int err;
    char *currtime = NULL;

    ALOGD("%s() got OEM_HOOK_STRINGS: %8p %lu", __func__, data, (long) datalen);

    for (i = (datalen / sizeof(char *)), cur = (const char **) data;
         i > 0; cur++, i--) {
        ALOGD("%s(): String: %s", __func__, *cur);
    }

    /* Only take the first string in the array for now */
    cur = (const char **) data;

    /* Check if this HOOK is a set clock command */
    if (NULL != strstr(*cur, "AT+CCLK=")) {
        /* Read time first to make sure an update is necessary */
        currtime = getTime();
        if (NULL == currtime)
            goto error;
        if (NULL != strstr(*cur, currtime)) {
            ALOGW("%s() Skipping setting same time again!", __func__);
            err = at_send_command_raw("AT", &atresponse);
            goto fake;
        }
    }

    err = at_send_command_raw(*cur, &atresponse);
fake:
    free(currtime);

    if ((err != AT_NOERROR && at_get_error_type(err) == AT_ERROR)
            || atresponse == NULL || atresponse->finalResponse == NULL)
        goto error;

    /* Count number of lines including prefix, intermediate and final response */
    linecount = 0;
    atline = atresponse->p_intermediates;
    while (atline != NULL && atline->line != NULL) {
        linecount++;
        atline = atline->p_next;
    }
    linecount++; /* for finalResponse */

    /* Create RIL response */
    if (linecount > 0) {
        cur = (const char **) alloca(linecount * sizeof (char *));
        if (cur != NULL) {
            linecount = 0;
            atline = atresponse->p_intermediates;
            while (atline != NULL && atline->line != NULL) {
                cur[linecount++] = atline->line;
                atline = atline->p_next;
            }
            cur[linecount++] = atresponse->finalResponse;
        } else
            goto error;
    }

    RIL_onRequestComplete(t, RIL_E_SUCCESS, cur, linecount * sizeof(char *));
    at_response_free(atresponse);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    at_response_free(atresponse);
}
                                                                                                                                                                                                                                                                                                                                                       u300-ril-oem.h                                                                                      0000644 0001750 0001750 00000002034 12271742740 013115  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#ifndef U300_RIL_OEM_H
#define U300_RIL_OEM_H 1

void requestOEMHookRaw(void *data, size_t datalen, RIL_Token t);
void requestOEMHookStrings(void *data, size_t datalen, RIL_Token t);

#endif
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    u300-ril-pdp.c                                                                                      0000644 0001750 0001750 00000066614 12316216645 013131  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
 **
 ** Copyright (C) ST-Ericsson AB 2008-2009
 ** Copyright 2006, The Android Open Source Project
 **
 ** Licensed under the Apache License, Version 2.0 (the "License");
 ** you may not use this file except in compliance with the License.
 ** You may obtain a copy of the License at
 **
 **     http://www.apache.org/licenses/LICENSE-2.0
 **
 ** Unless required by applicable law or agreed to in writing, software
 ** distributed under the License is distributed on an "AS IS" BASIS,
 ** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 ** See the License for the specific language governing permissions and
 ** limitations under the License.
 **
 ** Based on reference-ril by The Android Open Source Project.
 **
 ** Heavily modified for ST-Ericsson U300 modems.
 ** Author: Christian Bejram <christian.bejram@stericsson.com>
 **
 */

#include <stdio.h>
#include "atchannel.h"
#include "at_tok.h"
#include "misc.h"
#include <telephony/ril.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/if.h>
#include <linux/sockios.h>
#include <linux/route.h>
#include <cutils/properties.h>
#include "u300-ril-error.h"
#include "u300-ril-pdp.h"
#include "u300-ril-network.h"

#define LOG_TAG "RIL"
#include <utils/Log.h>

#include "u300-ril.h"
#include "u300-ril-device.h"
#include "net-utils.h"

#define getNWType(data) ((data) ? (data) : "IP")

/* Allocate and create an UCS-2 format string */
static char *ucs2StringCreate(const char *String);

/* Last pdp fail cause */
static int s_lastPdpFailCause = PDP_FAIL_ERROR_UNSPECIFIED;

#define MBM_ENAP_CONNECT_TIME 180      /* loops to wait for CONNECTION approx 180s */
#define MBM_ENAP_DISCONNECT_TIME 60   /* loops to wait for DISCONNECTION approx 60s */

static pthread_mutex_t s_e2nap_mutex = PTHREAD_MUTEX_INITIALIZER;
static int s_e2napState = E2NAP_STATE_UNKNOWN;
static int s_e2napCause = E2NAP_CAUSE_UNKNOWN;
static int s_DeactCalled = 0;
static int s_ActiveCID = -1;

static int parse_ip_information(char** addresses, char** gateways, char** dnses, in_addr_t* addr, in_addr_t* gateway)
{
    ATResponse* p_response = NULL;

    int err = -1;
    int number_of_entries = 0;
    int iterator = 0;
    int dnscnt = 0;
    char *intermediate_line = NULL;
    char *line_origin = NULL;

    *addresses = NULL;
    *gateways = NULL;
    *dnses = NULL;

    enum {
        IP = 1,
        GATEWAY,
        DNS
    };

    /* *E2IPCFG:
     *  (1,"10.155.68.129")(2,"10.155.68.131")(3,"80.251.192.244")(3,"80.251.192.245")
     */
    err = at_send_command_singleline("AT*E2IPCFG?", "*E2IPCFG:", &p_response);
    if (err != AT_NOERROR)
        return -1;

    err = at_tok_charcounter(p_response->p_intermediates->line, '(',
            &number_of_entries);
    if (err < 0 || number_of_entries == 0) {
        ALOGE("%s() Syntax error. Could not parse output", __func__);
        goto error;
    }

    intermediate_line = p_response->p_intermediates->line;

    /* Loop and collect information */
    for (iterator = 0; iterator < number_of_entries; iterator++) {
        int stat = 0;
        char *line_tok = NULL;
        char *address = NULL;
        char *remaining_intermediate_line = NULL;
        char* tmp_pointer = NULL;

        line_origin = line_tok = getFirstElementValue(intermediate_line,
                "(", ")", &remaining_intermediate_line);
        intermediate_line = remaining_intermediate_line;

        if (line_tok == NULL) {
            ALOGD("%s: No more connection info", __func__);
            break;
        }

        /* <stat> */
        err = at_tok_nextint(&line_tok, &stat);
        if (err < 0) {
            goto error;
        }

        /* <address> */
        err = at_tok_nextstr(&line_tok, &address);
        if (err < 0) {
            goto error;
        }

        switch (stat % 10) {
        case IP:
            if (!*addresses)
                *addresses = strdup(address);
            else {
                tmp_pointer = realloc(*addresses,
                        strlen(address) + strlen(*addresses) + 2);
                if (NULL == tmp_pointer) {
                    ALOGE("%s() Failed to allocate memory for addresses", __func__);
                    goto error;
                }
                *addresses = tmp_pointer;
                sprintf(*addresses, "%s %s", *addresses, address);
            }
            ALOGD("%s() IP Address: %s", __func__, address);
            if (inet_pton(AF_INET, address, addr) <= 0) {
                ALOGE("%s() inet_pton() failed for %s!", __func__, address);
                goto error;
            }
            break;

        case GATEWAY:
            if (!*gateways)
                *gateways = strdup(address);
            else {
                tmp_pointer = realloc(*gateways,
                        strlen(address) + strlen(*gateways) + 2);
                if (NULL == tmp_pointer) {
                    ALOGE("%s() Failed to allocate memory for gateways", __func__);
                    goto error;
                }
                *gateways = tmp_pointer;
                sprintf(*gateways, "%s %s", *gateways, address);
            }
            ALOGD("%s() GW: %s", __func__, address);
            if (inet_pton(AF_INET, address, gateway) <= 0) {
                ALOGE("%s() Failed inet_pton for gw %s!", __func__, address);
                goto error;
            }
            break;

        case DNS:
            dnscnt++;
            ALOGD("%s() DNS%d: %s", __func__, dnscnt, address);
            if (dnscnt == 1)
                *dnses = strdup(address);
            else if (dnscnt == 2) {
                tmp_pointer = realloc(*dnses,
                        strlen(address) + strlen(*dnses) + 2);
                if (NULL == tmp_pointer) {
                    ALOGE("%s() Failed to allocate memory for dnses", __func__);
                    goto error;
                }
                *dnses = tmp_pointer;
                sprintf(*dnses, "%s %s", *dnses, address);
            }
            break;
        }
        free(line_origin);
        line_origin = NULL;
    }

    at_response_free(p_response);
    return 0;

error:

    free(line_origin);
    free(*addresses);
    free(*gateways);
    free(*dnses);
    at_response_free(p_response);

    *gateways = NULL;
    *addresses = NULL;
    *dnses = NULL;
    return -1;
}

void requestOrSendPDPContextList(RIL_Token *token)
{
    ATResponse *atresponse = NULL;
    RIL_Data_Call_Response_v6 response;
    int e2napState = getE2napState();
    int err;
    int cid;
    char *line, *apn, *type;
    char* addresses = NULL;
    char* dnses = NULL;
    char* gateways = NULL;
    in_addr_t addr;
    in_addr_t gateway;

    memset(&response, 0, sizeof(response));
    response.ifname = ril_iface;

    err = at_send_command_multiline("AT+CGDCONT?", "+CGDCONT:", &atresponse);

    if (err != AT_NOERROR)
        goto error;

    line = atresponse->p_intermediates->line;
    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&line, &cid);
    if (err < 0)
        goto error;

    response.cid = s_ActiveCID;

    if (e2napState == E2NAP_STATE_CONNECTED)
        response.active = 2;

    err = at_tok_nextstr(&line, &type);
    if (err < 0)
        goto error;

    response.type = alloca(strlen(type) + 1);
    strcpy(response.type, type);

    err = at_tok_nextstr(&line, &apn);
    if (err < 0)
        goto error;

    at_response_free(atresponse);
    atresponse = NULL;

    /* TODO: Check if we should check ip for a specific CID instead */
    if (e2napState == E2NAP_STATE_CONNECTED) {
        if (parse_ip_information(&addresses, &gateways, &dnses, &addr, &gateway) < 0) {
            ALOGE("%s() Failed to parse network interface data", __func__);
            goto error;
        }
        response.addresses = addresses;
        response.gateways = gateways;
        response.dnses = dnses;
        response.suggestedRetryTime = -1;
    }

    if (token != NULL)
        RIL_onRequestComplete(*token, RIL_E_SUCCESS, &response,
                sizeof(RIL_Data_Call_Response_v6));
    else {
        response.status = s_lastPdpFailCause;
        response.suggestedRetryTime = -1;
        RIL_onUnsolicitedResponse(RIL_UNSOL_DATA_CALL_LIST_CHANGED, &response,
                sizeof(RIL_Data_Call_Response_v6));
    }

    free(addresses);
    free(gateways);
    free(dnses);

    return;

error:
    if (token != NULL)
        RIL_onRequestComplete(*token, RIL_E_GENERIC_FAILURE, NULL, 0);
    else
        RIL_onUnsolicitedResponse(RIL_UNSOL_DATA_CALL_LIST_CHANGED, NULL, 0);

    at_response_free(atresponse);
}

/**
 * RIL_UNSOL_PDP_CONTEXT_LIST_CHANGED
 *
 * Indicate a PDP context state has changed, or a new context
 * has been activated or deactivated.
 *
 * See also: RIL_REQUEST_PDP_CONTEXT_LIST
 */
void onPDPContextListChanged(void *param)
{
    (void) param;
    requestOrSendPDPContextList(NULL);
}

int getE2NAPFailCause(void)
{
    int e2napCause = getE2napCause();
    int e2napState = getE2napState();

    if (e2napState == E2NAP_STATE_CONNECTED)
        return 0;

    return e2napCause;
}

/**
 * RIL_REQUEST_PDP_CONTEXT_LIST
 *
 * Queries the status of PDP contexts, returning for each
 * its CID, whether or not it is active, and its PDP type,
 * APN, and PDP adddress.
 */
void requestPDPContextList(void *data, size_t datalen, RIL_Token t)
{
    (void) data;
    (void) datalen;
    requestOrSendPDPContextList(&t);
}

static int disconnect(void)
{
    int e2napState, i, err;

    err = at_send_command("AT*ENAP=0");
    if (err != AT_NOERROR && at_get_error_type(err) != CME_ERROR)
        return -1;

    for (i = 0; i < MBM_ENAP_DISCONNECT_TIME * 5; i++) {
        e2napState = getE2napState();
        if ((e2napState == E2NAP_STATE_DISCONNECTED) ||
                (e2napState == E2NAP_STATE_UNKNOWN) ||
                (RADIO_STATE_UNAVAILABLE == getRadioState()))
            break;
        usleep(200 * 1000);
    }
    return 0;
}

void mbm_check_error_cause(void)
{
    int e2napCause = getE2napCause();
    int e2napState = getE2napState();

    if (e2napState == E2NAP_STATE_CONNECTED) {
        s_lastPdpFailCause = PDP_FAIL_NONE;
        return;
    }

    if ((e2napCause < E2NAP_CAUSE_SUCCESS)) {
        s_lastPdpFailCause = PDP_FAIL_ERROR_UNSPECIFIED;
        return;
    }

    /* Protocol errors from 95 - 111
     * Standard defines only 95 - 101 and 111
     * Those 102-110 are missing
     */
    if (e2napCause >= GRPS_SEM_INCORRECT_MSG
            && e2napCause <= GPRS_MSG_NOT_COMP_PROTO_STATE) {
        s_lastPdpFailCause = PDP_FAIL_PROTOCOL_ERRORS;
        ALOGD("Connection error: %s cause: %s", e2napStateToString(e2napState),
                errorCauseToString(e2napCause));
        return;
    }

    if (e2napCause == GPRS_PROTO_ERROR_UNSPECIFIED) {
        s_lastPdpFailCause = PDP_FAIL_PROTOCOL_ERRORS;
        ALOGD("Connection error: %s cause: %s", e2napStateToString(e2napState),
                errorCauseToString(e2napCause));
        return;
    }

    ALOGD("Connection state: %s cause: %s", e2napStateToString(e2napState),
            errorCauseToString(e2napCause));

    switch (e2napCause) {
    case E2NAP_CAUSE_GPRS_ATTACH_NOT_POSSIBLE:
        s_lastPdpFailCause = PDP_FAIL_SIGNAL_LOST;
        break;
    case E2NAP_CAUSE_NO_SIGNAL_CONN:
        s_lastPdpFailCause = PDP_FAIL_ACTIVATION_REJECT_UNSPECIFIED;
        break;
    case GPRS_OP_DETERMINED_BARRING:
        s_lastPdpFailCause = PDP_FAIL_OPERATOR_BARRED;
        break;
    case GPRS_INSUFFICIENT_RESOURCES:
        s_lastPdpFailCause = PDP_FAIL_INSUFFICIENT_RESOURCES;
        break;
    case GPRS_UNKNOWN_APN:
        s_lastPdpFailCause = PDP_FAIL_MISSING_UKNOWN_APN;
        break;
    case GPRS_UNKNOWN_PDP_TYPE:
        s_lastPdpFailCause = PDP_FAIL_UNKNOWN_PDP_ADDRESS_TYPE;
        break;
    case GPRS_USER_AUTH_FAILURE:
        s_lastPdpFailCause = PDP_FAIL_USER_AUTHENTICATION;
        break;
    case GPRS_ACT_REJECTED_GGSN:
        s_lastPdpFailCause = PDP_FAIL_ACTIVATION_REJECT_GGSN;
        break;
    case GPRS_ACT_REJECTED_UNSPEC:
        s_lastPdpFailCause = PDP_FAIL_ACTIVATION_REJECT_UNSPECIFIED;
        break;
    case GPRS_SERVICE_OPTION_NOT_SUPP:
        s_lastPdpFailCause = PDP_FAIL_SERVICE_OPTION_NOT_SUPPORTED;
        break;
    case GPRS_REQ_SER_OPTION_NOT_SUBS:
        s_lastPdpFailCause = PDP_FAIL_SERVICE_OPTION_NOT_SUBSCRIBED;
        break;
    case GPRS_SERVICE_OUT_OF_ORDER:
        s_lastPdpFailCause = PDP_FAIL_SERVICE_OPTION_OUT_OF_ORDER;
        break;
    case GPRS_NSAPI_ALREADY_USED:
        s_lastPdpFailCause = PDP_FAIL_NSAPI_IN_USE;
        break;
    default:
        break;
    }
}

static int setCharEncoding(const char *enc)
{
    int err;
    err = at_send_command("AT+CSCS=\"%s\"", enc);

    if (err != AT_NOERROR) {
        ALOGE("%s() Failed to set AT+CSCS=%s", __func__, enc);
        return -1;
    }
    return 0;
}

static char *getCharEncoding(void)
{
    int err;
    char *line, *chSet;
    char *result = NULL;
    ATResponse *p_response = NULL;
    err = at_send_command_singleline("AT+CSCS?", "+CSCS:", &p_response);

    if (err != AT_NOERROR) {
        ALOGE("%s() Failed to read AT+CSCS?", __func__);
        return NULL;
    }

    line = p_response->p_intermediates->line;
    err = at_tok_start(&line);
    if (err < 0) {
        at_response_free(p_response);
        return NULL;
    }

    err = at_tok_nextstr(&line, &chSet);
    if (err < 0) {
        at_response_free(p_response);
        return NULL;
    }

    /* If not any of the listed below, assume UCS-2 */
    if (!strcmp(chSet, "GSM") || !strcmp(chSet, "IRA")
            || !strncmp(chSet, "8859", 4) || !strcmp(chSet, "UTF-8")) {
        result = strdup(chSet);
    } else
        result = strdup("UCS-2");

    at_response_free(p_response);
    return result;
}

static int networkAuth(const char *authentication, const char *user,
        const char *pass, int index)
{
    char *atAuth = NULL, *atUser = NULL, *atPass = NULL;
    char *chSet = NULL;
    char *end;
    long int auth;
    int err;
    char *oldenc;
    enum {
        NO_PAP_OR_CHAP,
        PAP,
        CHAP,
        PAP_OR_CHAP,
    };

    auth = strtol(authentication, &end, 10);
    if (end == NULL)
        return -1;

    switch (auth) {
    case NO_PAP_OR_CHAP:
        /* PAP and CHAP is never performed., only none
         * PAP never performed; CHAP never performed */
        atAuth = "00001";
        break;
    case PAP:
        /* PAP may be performed; CHAP is never performed.
         * PAP may be performed; CHAP never performed */
        atAuth = "00011";
        break;
    case CHAP:
        /* CHAP may be performed; PAP is never performed
         * PAP never performed; CHAP may be performed */
        atAuth = "00101";
        break;
    case PAP_OR_CHAP:
        /* PAP / CHAP may be performed - baseband dependent.
         * PAP may be performed; CHAP may be performed. */
        atAuth = "00111";
        break;
    default:
        ALOGE("%s() Unrecognized authentication type %s."
            "Using default value (CHAP, PAP and None)", __func__, authentication);
        atAuth = "00111";
        break;
    }
    if (!user)
        user = "";
    if (!pass)
        pass = "";

    if ((NULL != strchr(user, '\\')) || (NULL != strchr(pass, '\\'))) {
        /* Because of module FW issues, some characters need UCS-2 format to be supported
         * in the user and pass strings. Read current setting, change to UCS-2 format,
         * send *EIAAUW command, and finally change back to previous character set.
         */
        oldenc = getCharEncoding();
        setCharEncoding("UCS2");

        atUser = ucs2StringCreate(user);
        atPass = ucs2StringCreate(pass);
        /* Even if sending of the command below would be erroneous, we should still
         * try to change back the character set to the original.
         */
        err = at_send_command("AT*EIAAUW=%d,1,\"%s\",\"%s\",%s", index,
                atUser, atPass, atAuth);
        free(atPass);
        free(atUser);

        /* Set back to the original character set */
        chSet = ucs2StringCreate(oldenc);
        setCharEncoding(chSet);
        free(chSet);
        free(oldenc);

        if (err != AT_NOERROR)
            return -1;
    } else {
        /* No need to change to UCS-2 during user and password setting */
        err = at_send_command("AT*EIAAUW=%d,1,\"%s\",\"%s\",%s", index,
                user, pass, atAuth);

        if (err != AT_NOERROR)
            return -1;
    }

    return 0;
}

void requestSetupDefaultPDP(void *data, size_t datalen, RIL_Token t)
{
    in_addr_t addr;
    in_addr_t gateway;

    const char *apn, *user, *pass, *auth;
    char *addresses = NULL;
    char *gateways = NULL;
    char *dnses = NULL;
    const char *type = NULL;

    RIL_Data_Call_Response_v6 response;

    int e2napState = getE2napState();
    int err = -1;
    int cme_err, i, prof;

    (void) data;
    (void) datalen;

    prof = atoi(((const char **) data)[1]);
    apn = ((const char **) data)[2];
    user = ((const char **) data)[3];
    pass = ((const char **) data)[4];
    auth = ((const char **) data)[5];
    type = getNWType(((const char **) data)[6]);

    s_lastPdpFailCause = PDP_FAIL_ERROR_UNSPECIFIED;

    memset(&response, 0, sizeof(response));
    response.ifname = ril_iface;
    response.cid = prof + 1;
    response.active = 0;
    response.type = (char *) type;
    response.suggestedRetryTime = -1;

    /* Handle case where Android framework tries to setup multiple PDPs
       when sending/receiving MMS. Tear down the default context if any
       attempt is made to setup a new context with different DataProfile.
       Requires changes to Android framework (RILConstants.java and
       GsmDataConnectionTracker.java). This need to be in place until the
       framework properly handles priorities on APNs */
    if (e2napState > E2NAP_STATE_DISCONNECTED) {
        if (prof > RIL_DATA_PROFILE_DEFAULT) {
            ALOGD("%s() tearing down default cid:%d to allow cid:%d",
                        __func__, s_ActiveCID, prof + 1);
            s_DeactCalled = 1;
            if (disconnect()) {
                goto down;
            } else {
                e2napState = getE2napState();

                if (e2napState != E2NAP_STATE_DISCONNECTED)
                    goto error;

                if (ifc_init())
                    goto error;

                if (ifc_down(ril_iface))
                    goto error;

                ifc_close();
                requestOrSendPDPContextList(NULL);
            }
        } else {
            ALOGE("%s() denying data connection to APN '%s' Multiple PDP not supported!",
                                __func__, apn);
            response.status = PDP_FAIL_INSUFFICIENT_RESOURCES;
            RIL_onRequestComplete(t, RIL_E_SUCCESS, &response, sizeof(response));
            return;
        }
    }

down:
    e2napState = setE2napState(E2NAP_STATE_UNKNOWN);

    ALOGD("%s() requesting data connection to APN '%s'", __func__, apn);

    if (ifc_init()) {
        ALOGE("%s() Failed to set up ifc!", __func__);
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
        return;
    }

    if (ifc_down(ril_iface)) {
        ALOGE("%s() Failed to bring down %s!", __func__, ril_iface);
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
        return;
    }

    err = at_send_command("AT+CGDCONT=%d,\"IP\",\"%s\"", RIL_CID_IP, apn);
    if (err != AT_NOERROR) {
        cme_err = at_get_cme_error(err);
        ALOGE("%s() CGDCONT failed: %d, cme: %d", __func__, err, cme_err);
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
        return;
    }

    if (networkAuth(auth, user, pass, RIL_CID_IP)) {
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
        return;
    }

    /* Start data on PDP context for IP */
    err = at_send_command("AT*ENAP=1,%d", RIL_CID_IP);
    if (err != AT_NOERROR) {
        cme_err = at_get_cme_error(err);
        ALOGE("requestSetupDefaultPDP: ENAP failed: %d  cme: %d", err, cme_err);
        goto error;
    }

    for (i = 0; i < MBM_ENAP_CONNECT_TIME * 5; i++) {
        e2napState = getE2napState();
        if (e2napState == E2NAP_STATE_CONNECTED
                || e2napState == E2NAP_STATE_DISCONNECTED
                || RADIO_STATE_UNAVAILABLE == getRadioState()) {
            ALOGD("%s() %s", __func__, e2napStateToString(e2napState));
            break;
        }
        usleep(200 * 1000);
    }

    e2napState = getE2napState();

    if (e2napState != E2NAP_STATE_CONNECTED)
        goto error;

    if (parse_ip_information(&addresses, &gateways, &dnses, &addr, &gateway) < 0) {
        ALOGE("%s() Failed to parse network interface data", __func__);
        goto error;
    }

    response.addresses = addresses;
    response.gateways = gateways;
    response.dnses = dnses;
    ALOGI("%s() Setting up interface %s,%s,%s",
        __func__, response.addresses, response.gateways, response.dnses);

    e2napState = getE2napState();

    if (e2napState == E2NAP_STATE_DISCONNECTED)
        goto error; /* we got disconnected */

    /* Don't use android netutils. We use our own and get the routing correct.
     * Carl Nordbeck */
    if (ifc_configure(ril_iface, addr, gateway))
        ALOGE("%s() Failed to configure the interface %s", __func__, ril_iface);

    ALOGI("IP Address %s, %s", addresses, e2napStateToString(e2napState));

    e2napState = getE2napState();

    if (e2napState == E2NAP_STATE_DISCONNECTED)
        goto error; /* we got disconnected */

    response.active = 2;
    response.status = 0;
    s_ActiveCID = response.cid;

    RIL_onRequestComplete(t, RIL_E_SUCCESS, &response, sizeof(response));

    free(addresses);
    free(gateways);
    free(dnses);

    startPollFastDormancy();

    return;

error:

    mbm_check_error_cause();
    response.status = s_lastPdpFailCause;

    /* Restore enap state and wait for enap to report disconnected*/
    disconnect();

    RIL_onRequestComplete(t, RIL_E_SUCCESS, &response, sizeof(response));

    free(addresses);
    free(gateways);
    free(dnses);
}

/* CHECK There are several error cases if PDP deactivation fails
 * 24.008: 8, 25, 36, 38, 39, 112
 */
void requestDeactivateDefaultPDP(void *data, size_t datalen, RIL_Token t)
{
    int e2napState = getE2napState();
    int cid = atoi(((const char **) data)[0]);
    (void) datalen;

    if (cid != s_ActiveCID) {
        ALOGD("%s() Not tearing down cid:%d since cid:%d is active", __func__,
                cid, s_ActiveCID);
        goto done;
    }

    s_DeactCalled = 1;

    if (e2napState == E2NAP_STATE_CONNECTING)
        ALOGW("%s() Tear down connection while connection setup in progress", __func__);

    if (e2napState != E2NAP_STATE_DISCONNECTED) {
        if (disconnect())
            goto error;

        e2napState = getE2napState();

        if (e2napState != E2NAP_STATE_DISCONNECTED)
            goto error;

        /* Bring down the interface as well. */
        if (ifc_init())
            goto error;

        if (ifc_down(ril_iface))
            goto error;

        ifc_close();
    }

done:
    RIL_onRequestComplete(t, RIL_E_SUCCESS, NULL, 0);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
}

/**
 * RIL_REQUEST_LAST_PDP_FAIL_CAUSE
 *
 * Requests the failure cause code for the most recently failed PDP
 * context activate.
 *
 * See also: RIL_REQUEST_LAST_CALL_FAIL_CAUSE.
 *
 */
void requestLastPDPFailCause(void *data, size_t datalen, RIL_Token t)
{
    (void) data;
    (void) datalen;
    RIL_onRequestComplete(t, RIL_E_SUCCESS, &s_lastPdpFailCause, sizeof(int));
}

/**
 * Returns a pointer to allocated memory filled with AT command
 * UCS-2 formatted string corresponding to the input string.
 * Note: Caller need to take care of freeing the
 *  allocated memory by calling free( ) when the
 *  created string is no longer used.
 */
static char *ucs2StringCreate(const char *iString)
{
    int slen = 0;
    int idx = 0;
    char *ucs2String = NULL;

    /* In case of NULL input, create an empty string as output */
    if (NULL == iString)
        slen = 0;
    else
        slen = strlen(iString);

    ucs2String = (char *) malloc(sizeof(char) * (slen * 4 + 1));
    for (idx = 0; idx < slen; idx++)
        sprintf(&ucs2String[idx * 4], "%04x", iString[idx]);
    ucs2String[idx * 4] = '\0';
    return ucs2String;
}

void onConnectionStateChanged(const char *s)
{
    int m_state = -1, m_cause = -1, err;
    int commas;

    err = at_tok_start((char **) &s);
    if (err < 0)
        return;

    /* Count number of commas */
    err = at_tok_charcounter((char *) s, ',', &commas);
    if (err < 0)
        return;

    err = at_tok_nextint((char **) &s, &m_state);
    if (err < 0 || m_state < E2NAP_STATE_DISCONNECTED
            || m_state > E2NAP_STATE_CONNECTING) {
        m_state = -1;
        return;
    }

    err = at_tok_nextint((char **) &s, &m_cause);
    /* The <cause> will only be indicated/considered when <state>
     * is disconnected */
    if (err < 0 || m_cause < E2NAP_CAUSE_SUCCESS || m_cause > E2NAP_CAUSE_MAXIMUM
            || m_state != E2NAP_STATE_DISCONNECTED)
        m_cause = -1;

    if (commas == 3) {
        int m_state2 = -1, m_cause2 = -1;
        err = at_tok_nextint((char **) &s, &m_state2);
        if (err < 0 || m_state2 < E2NAP_STATE_DISCONNECTED
                || m_state2 > E2NAP_STATE_CONNECTED) {
            m_state = -1;
            return;
        }

        if (m_state2 == E2NAP_STATE_DISCONNECTED) {
            err = at_tok_nextint((char **) &s, &m_cause2);
            if (err < 0 || m_cause2 < E2NAP_CAUSE_SUCCESS
                    || m_cause2 > E2NAP_CAUSE_MAXIMUM) {
                m_cause2 = -1;
            }
        }

        if ((err = pthread_mutex_lock(&s_e2nap_mutex)) != 0)
            ALOGE("%s() failed to take e2nap mutex: %s", __func__,
                    strerror(err));

        if (m_state == E2NAP_STATE_CONNECTING || m_state2 == E2NAP_STATE_CONNECTING) {
            s_e2napState = E2NAP_STATE_CONNECTING;
        } else if (m_state == E2NAP_STATE_CONNECTED) {
            s_e2napCause = m_cause2;
            s_e2napState = E2NAP_STATE_CONNECTED;
        } else if (m_state2 == E2NAP_STATE_CONNECTED) {
            s_e2napCause = m_cause;
            s_e2napState = E2NAP_STATE_CONNECTED;
        } else {
            s_e2napCause = m_cause;
            s_e2napState = E2NAP_STATE_DISCONNECTED;
        }
        if ((err = pthread_mutex_unlock(&s_e2nap_mutex)) != 0)
            ALOGE("%s() failed to release e2nap mutex: %s", __func__,
                    strerror(err));
    } else {
        if ((err = pthread_mutex_lock(&s_e2nap_mutex)) != 0)
            ALOGE("%s() failed to take e2nap mutex: %s", __func__,
                    strerror(err));

        s_e2napState = m_state;
        s_e2napCause = m_cause;
        if ((err = pthread_mutex_unlock(&s_e2nap_mutex)) != 0)
            ALOGE("%s() failed to release e2nap mutex: %s", __func__,
                    strerror(err));

    }

    mbm_check_error_cause();

    if (m_state == E2NAP_STATE_DISCONNECTED) {
        /* Bring down the interface as well. */
        if (!(ifc_init())) {
            ifc_down(ril_iface);
            ifc_close();
        } else
            ALOGE("%s() Failed to set up ifc!", __func__);
    }

    if ((m_state == E2NAP_STATE_DISCONNECTED) && (s_DeactCalled == 0)) {
        enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, onPDPContextListChanged, NULL,
                NULL);
    }
    s_DeactCalled = 0;
}

int getE2napState(void)
{
    return s_e2napState;
}

int getE2napCause(void)
{
    return s_e2napCause;
}

int setE2napState(int state)
{
    s_e2napState = state;
    return s_e2napState;
}

int setE2napCause(int state)
{
    s_e2napCause = state;
    return s_e2napCause;
}
                                                                                                                    u300-ril-pdp.h                                                                                      0000644 0001750 0001750 00000002652 12271742740 013126  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#ifndef U300_RIL_PDP_H
#define U300_RIL_PDP_H 1

void requestOrSendPDPContextList(RIL_Token *t);
void onPDPContextListChanged(void *param);
void requestPDPContextList(void *data, size_t datalen, RIL_Token t);
void requestSetupDefaultPDP(void *data, size_t datalen, RIL_Token t);
void requestDeactivateDefaultPDP(void *data, size_t datalen, RIL_Token t);
void requestLastPDPFailCause(void *data, size_t datalen, RIL_Token t);
void onConnectionStateChanged(const char *s);
int getE2napState(void);
int getE2napCause(void);
int setE2napState(int state);
int setE2napCause(int state);

#endif
                                                                                      u300-ril-requestdatahandler.c                                                                       0000644 0001750 0001750 00000021651 12300142157 016203  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on the Android ril daemon and reference RIL by 
** The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#include <stdlib.h>
#include <telephony/ril.h>
#include <assert.h>

#define LOG_TAG "RIL"
#include <utils/Log.h>

/* Handler functions. The names are because we cheat by including
 * ril_commands.h from rild. In here we generate local allocations
 * of the data representations, as well as free:ing them after
 * they've been handled.
 *
 * This design might not be ideal, but considering the alternatives,
 * it's good enough.
 */
static void *dummyDispatch(void *data, size_t datalen);
 
#define dispatchCdmaSms dummyDispatch
#define dispatchCdmaSmsAck dummyDispatch
#define dispatchCdmaBrSmsCnf dummyDispatch
#define dispatchRilCdmaSmsWriteArgs dummyDispatch
#define dispatchCdmaSubscriptionSource dummyDispatch
#define dispatchVoiceRadioTech dummyDispatch

#define dispatchDepersonalization dummyDispatch
#define dispatchImsSms dummyDispatch
#define dispatchUiccSubscripton dummyDispatch

#define dispatchSetInitialAttachApn dummyDispatch

static void *dispatchCallForward(void *data, size_t datalen);
static void *dispatchDial(void *data, size_t datalen);
static void *dispatchSIM_IO(void *data, size_t datalen);
static void *dispatchSmsWrite(void *data, size_t datalen);
static void *dispatchString(void *data, size_t datalen);
static void *dispatchStrings(void *data, size_t datalen);
static void *dispatchRaw(void *data, size_t datalen);
static void *dispatchVoid(void *data, size_t datalen);
static void *dispatchGsmBrSmsCnf(void *data, size_t datalen);

#define dispatchInts dispatchRaw

static void dummyResponse(void);

#define responseCallForwards dummyResponse
#define responseCallList dummyResponse
#define responseCellList dummyResponse
#define responseContexts dummyResponse
#define responseInts dummyResponse
#define responseRaw dummyResponse
#define responseSIM_IO dummyResponse
#define responseSMS dummyResponse
#define responseString dummyResponse
#define responseStrings dummyResponse
#define responseVoid dummyResponse
#define responseStringsNetworks dummyResponse

#define responseSimStatus dummyResponse
#define responseRilSignalStrength dummyResponse
#define responseDataCallList dummyResponse
#define responseGsmBrSmsCnf dummyResponse
#define responseCdmaBrSmsCnf dummyResponse

#define responseCellInfoList dummyResponse
#define responseGetDataCallProfile dummyResponse
#define responseUiccSubscription dummyResponse

#define dispatchDataCall dispatchStrings
#define responseSetupDataCall responseStrings


/*
should be looked into how dispatchDataCall and others really should be handled,
not just use dispatchStrings but it seems to work. This feature
was added in android 3.0, might be just be a nicer way handling
things seperatly. This has no impact on older versions and should
work as it is on both (hence we can't really remove code from
dispatchStrings if it should be in distpatchDataCall).

static void *dispatchDataCall(void *data, size_t datalen){
...
} */

typedef struct CommandInfo {
    int requestId;
    void *(*dispatchFunction) (void *data, size_t datalen);
    void (*responseFunction) (void);
} CommandInfo;

/* RILD made me do it! */
static CommandInfo s_commandInfo[] = {
#include <ril_commands.h>
};

static void *dummyDispatch(void *data, size_t datalen)
{
    (void) data; (void) datalen;
    return 0;
}

static void dummyResponse(void)
{
    return;
}

/**
 * dupRequestData will copy the data pointed to by *data, returning a pointer
 * to a freshly allocated representation of the data.
 */
void *dupRequestData(int requestId, void *data, size_t datalen)
{
    CommandInfo *ci = &s_commandInfo[requestId];

    return ci->dispatchFunction(data, datalen);
}

static void *dispatchCallForward(void *data, size_t datalen)
{
    RIL_CallForwardInfo *ret = dispatchRaw(data, datalen);

    if (ret->number)
        ret->number = strdup(ret->number);

    return ret;
}

static void *dispatchDial(void *data, size_t datalen)
{
    RIL_Dial *ret = dispatchRaw(data, datalen);

    if (ret->address)
        ret->address = strdup(ret->address);

    return ret;
}

static void *dispatchSIM_IO(void *data, size_t datalen)
{
    RIL_SIM_IO_v6 *ret = dispatchRaw(data, datalen);

    if (ret->path)
        ret->path = strdup(ret->path);
    if (ret->data)
        ret->data = strdup(ret->data);
    if (ret->pin2)
        ret->pin2 = strdup(ret->pin2);
    if (ret->aidPtr)
        ret->aidPtr = strdup(ret->aidPtr);

    return ret;
}

static void *dispatchSmsWrite(void *data, size_t datalen)
{
    RIL_SMS_WriteArgs *ret = dispatchRaw(data, datalen);

    if (ret->pdu)
        ret->pdu = strdup(ret->pdu);

    if (ret->smsc)
        ret->smsc = strdup(ret->smsc);

    return ret;
}

static void *dispatchString(void *data, size_t datalen)
{
	(void) data; (void) datalen;
    assert(datalen == sizeof(char *));

    if (data)
        return strdup((char *) data);

    return NULL;
}

static void *dispatchStrings(void *data, size_t datalen)
{
    char **a = (char **)data;
    char **ret;
    int strCount = datalen / sizeof(char *);
    int i;

    assert((datalen % sizeof(char *)) == 0);

    ret = malloc(strCount * sizeof(char *));
    memset(ret, 0, sizeof(char *) * strCount);

    for (i = 0; i < strCount; i++) {
        if (a[i])
            ret[i] = strdup(a[i]);
    }

    return (void *) ret;
}

static void *dispatchGsmBrSmsCnf(void *data, size_t datalen)
{
    RIL_GSM_BroadcastSmsConfigInfo **a = 
        (RIL_GSM_BroadcastSmsConfigInfo **) data;
    int count;
    void **ret;
    int i;

    count = datalen / sizeof(RIL_GSM_BroadcastSmsConfigInfo *);

    ret = malloc(count * sizeof(RIL_GSM_BroadcastSmsConfigInfo *));
    memset(ret, 0, sizeof(*ret));

    for (i = 0; i < count; i++) {
        if (a[i])
            ret[i] = dispatchRaw(a[i], sizeof(RIL_GSM_BroadcastSmsConfigInfo));
    }

    return ret;
}

static void *dispatchRaw(void *data, size_t datalen)
{
    void *ret = malloc(datalen);
    memcpy(ret, data, datalen);

    return (void *) ret;
}

static void *dispatchVoid(void *data, size_t datalen)
{
    (void) data; (void) datalen;
    return NULL;
}

static void freeDial(void *data)
{
    RIL_Dial *d = data;

    if (d->address)
        free(d->address);

    free(d);
}

static void freeStrings(void *data, size_t datalen)
{
    int count = datalen / sizeof(char *);
    int i;

    for (i = 0; i < count; i++) {
        if (((char **) data)[i])
            free(((char **) data)[i]);
    }

    free(data);
}

static void freeGsmBrSmsCnf(void *data, size_t datalen)
{
    int count = datalen / sizeof(RIL_GSM_BroadcastSmsConfigInfo);
    int i;

    for (i = 0; i < count; i++) {
        if (((RIL_GSM_BroadcastSmsConfigInfo **) data)[i])
            free(((RIL_GSM_BroadcastSmsConfigInfo **) data)[i]);
    }

    free(data);
}

static void freeSIM_IO(void *data)
{
    RIL_SIM_IO_v6 *sio = data;

    if (sio->path)
        free(sio->path);
    if (sio->data)
        free(sio->data);
    if (sio->pin2)
        free(sio->pin2);
    if (sio->aidPtr)
        free(sio->aidPtr);

    free(sio);
}

static void freeSmsWrite(void *data)
{
    RIL_SMS_WriteArgs *args = data;

    if (args->pdu)
        free(args->pdu);

    if (args->smsc)
        free(args->smsc);

    free(args);
}

static void freeCallForward(void *data)
{
    RIL_CallForwardInfo *cff = data;

    if (cff->number)
        free(cff->number);

    free(cff);
}

void freeRequestData(int requestId, void *data, size_t datalen)
{
    CommandInfo *ci = &s_commandInfo[requestId];

    if (ci->dispatchFunction == dispatchInts ||
        ci->dispatchFunction == dispatchRaw ||
        ci->dispatchFunction == dispatchString) {
        if (data)
            free(data);
    } else if (ci->dispatchFunction == dispatchStrings) {
        freeStrings(data, datalen);
    } else if (ci->dispatchFunction == dispatchSIM_IO) {
        freeSIM_IO(data);
    } else if (ci->dispatchFunction == dispatchDial) {
        freeDial(data);
    } else if (ci->dispatchFunction == dispatchVoid) {
    } else if (ci->dispatchFunction == dispatchCallForward) {
        freeCallForward(data);
    } else if (ci->dispatchFunction == dispatchSmsWrite) {
        freeSmsWrite(data);
    } else if (ci->dispatchFunction == dispatchGsmBrSmsCnf) {
        freeGsmBrSmsCnf(data, datalen);
    }
}
                                                                                       u300-ril-requestdatahandler.h                                                                       0000644 0001750 0001750 00000001615 12271742740 016221  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2009
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/
#ifndef _U300_RIL_REQUESTDATAHANDLER_H
#define _U300_RIL_REQUESTDATAHANDLER_H 1

void *dupRequestData(int requestId, void *data, size_t datalen);
void freeRequestData(int requestId, void *data, size_t datalen);

#endif
                                                                                                                   u300-ril-sim.c                                                                                      0000644 0001750 0001750 00000124662 12271742740 013134  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#include <telephony/ril.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include "atchannel.h"
#include "at_tok.h"
#include "fcp_parser.h"
#include "u300-ril.h"
#include "u300-ril-sim.h"
#include "u300-ril-messaging.h"
#include "u300-ril-device.h"
#include "misc.h"

#define LOG_TAG "RIL"
#include <utils/Log.h>

typedef enum {
    SIM_ABSENT = 0,                     /* SIM card is not inserted */
    SIM_NOT_READY = 1,                  /* SIM card is not ready */
    SIM_READY = 2,                      /* radiostate = RADIO_STATE_SIM_READY */
    SIM_PIN = 3,                        /* SIM PIN code lock */
    SIM_PUK = 4,                        /* SIM PUK code lock */
    SIM_NETWORK_PERSO = 5,              /* Network Personalization lock */
    SIM_PIN2 = 6,                       /* SIM PIN2 lock */
    SIM_PUK2 = 7,                       /* SIM PUK2 lock */
    SIM_NETWORK_SUBSET_PERSO = 8,       /* Network Subset Personalization */
    SIM_SERVICE_PROVIDER_PERSO = 9,     /* Service Provider Personalization */
    SIM_CORPORATE_PERSO = 10,           /* Corporate Personalization */
    SIM_SIM_PERSO = 11,                 /* SIM/USIM Personalization */
    SIM_STERICSSON_LOCK = 12,           /* ST-Ericsson Extended SIM */
    SIM_BLOCKED = 13,                   /* SIM card is blocked */
    SIM_PERM_BLOCKED = 14,              /* SIM card is permanently blocked */
    SIM_NETWORK_PERSO_PUK = 15,         /* Network Personalization PUK */
    SIM_NETWORK_SUBSET_PERSO_PUK = 16,  /* Network Subset Perso. PUK */
    SIM_SERVICE_PROVIDER_PERSO_PUK = 17,/* Service Provider Perso. PUK */
    SIM_CORPORATE_PERSO_PUK = 18,       /* Corporate Personalization PUK */
    SIM_SIM_PERSO_PUK = 19,             /* SIM Personalization PUK (unused) */
    SIM_PUK2_PERM_BLOCKED = 20          /* PUK2 is permanently blocked */
} SIM_Status;

typedef enum {
    UICC_TYPE_UNKNOWN,
    UICC_TYPE_SIM,
    UICC_TYPE_USIM,
} UICC_Type;

/*
 * The following list contains values for the structure "RIL_AppStatus" to be
 * sent to Android on a given SIM state. It is indexed by the SIM_Status above.
 */
static const RIL_AppStatus app_status_array[] = {
    /*
     * RIL_AppType,  RIL_AppState,
     * RIL_PersoSubstate,
     * Aid pointer, App Label pointer, PIN1 replaced,
     * RIL_PinState (PIN1),
     * RIL_PinState (PIN2)
     */
    /* SIM_ABSENT = 0 */
    {
        RIL_APPTYPE_UNKNOWN, RIL_APPSTATE_UNKNOWN,
        RIL_PERSOSUBSTATE_UNKNOWN,
        NULL, NULL, 0,
        RIL_PINSTATE_UNKNOWN,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_NOT_READY = 1 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_DETECTED,
        RIL_PERSOSUBSTATE_UNKNOWN,
        NULL, NULL, 0,
        RIL_PINSTATE_UNKNOWN,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_READY = 2 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_READY,
        RIL_PERSOSUBSTATE_READY,
        NULL, NULL, 0,
        RIL_PINSTATE_UNKNOWN,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_PIN = 3 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_PIN,
        RIL_PERSOSUBSTATE_UNKNOWN,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_NOT_VERIFIED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_PUK = 4 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_PUK,
        RIL_PERSOSUBSTATE_UNKNOWN,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_BLOCKED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_NETWORK_PERSO = 5 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_SUBSCRIPTION_PERSO,
        RIL_PERSOSUBSTATE_SIM_NETWORK,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_NOT_VERIFIED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_PIN2 = 6 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_READY,
        RIL_PERSOSUBSTATE_UNKNOWN,
        NULL, NULL, 0,
        RIL_PINSTATE_UNKNOWN,
        RIL_PINSTATE_ENABLED_NOT_VERIFIED
    },
    /* SIM_PUK2 = 7 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_READY,
        RIL_PERSOSUBSTATE_UNKNOWN,
        NULL, NULL, 0,
        RIL_PINSTATE_UNKNOWN,
        RIL_PINSTATE_ENABLED_BLOCKED
    },
    /* SIM_NETWORK_SUBSET_PERSO = 8 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_SUBSCRIPTION_PERSO,
        RIL_PERSOSUBSTATE_SIM_NETWORK_SUBSET,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_NOT_VERIFIED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_SERVICE_PROVIDER_PERSO = 9 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_SUBSCRIPTION_PERSO,
        RIL_PERSOSUBSTATE_SIM_SERVICE_PROVIDER,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_NOT_VERIFIED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_CORPORATE_PERSO = 10 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_SUBSCRIPTION_PERSO,
        RIL_PERSOSUBSTATE_SIM_CORPORATE,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_NOT_VERIFIED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_SIM_PERSO = 11 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_SUBSCRIPTION_PERSO,
        RIL_PERSOSUBSTATE_SIM_SIM,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_NOT_VERIFIED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_STERICSSON_LOCK = 12 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_SUBSCRIPTION_PERSO,
        RIL_PERSOSUBSTATE_UNKNOWN,    /* API (ril.h) does not have this lock */
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_NOT_VERIFIED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_BLOCKED = 13 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_UNKNOWN,
        RIL_PERSOSUBSTATE_UNKNOWN,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_BLOCKED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_PERM_BLOCKED = 14 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_UNKNOWN,
        RIL_PERSOSUBSTATE_UNKNOWN,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_PERM_BLOCKED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_NETWORK_PERSO_PUK = 15 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_SUBSCRIPTION_PERSO,
        RIL_PERSOSUBSTATE_SIM_NETWORK_PUK,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_NOT_VERIFIED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_NETWORK_SUBSET_PERSO_PUK = 16 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_SUBSCRIPTION_PERSO,
        RIL_PERSOSUBSTATE_SIM_NETWORK_SUBSET_PUK,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_NOT_VERIFIED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_SERVICE_PROVIDER_PERSO_PUK = 17 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_SUBSCRIPTION_PERSO,
        RIL_PERSOSUBSTATE_SIM_SERVICE_PROVIDER_PUK,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_NOT_VERIFIED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_CORPORATE_PERSO_PUK = 18 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_SUBSCRIPTION_PERSO,
        RIL_PERSOSUBSTATE_SIM_CORPORATE_PUK,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_NOT_VERIFIED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_SIM_PERSO_PUK = 19 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_SUBSCRIPTION_PERSO,
        RIL_PERSOSUBSTATE_SIM_SIM_PUK,
        NULL, NULL, 0,
        RIL_PINSTATE_ENABLED_NOT_VERIFIED,
        RIL_PINSTATE_UNKNOWN
    },
    /* SIM_PUK2_PERM_BLOCKED = 20 */
    {
        RIL_APPTYPE_SIM, RIL_APPSTATE_UNKNOWN,
        RIL_PERSOSUBSTATE_UNKNOWN,
        NULL, NULL, 0,
        RIL_PINSTATE_UNKNOWN,
        RIL_PINSTATE_ENABLED_PERM_BLOCKED
    }
};

static const struct timespec TIMEVAL_SIMPOLL = { 1, 0 };
static const struct timespec TIMEVAL_SIMRESET = { 60, 0 };
static int sim_hotswap;

/* All files listed under ADF_USIM in 3GPP TS 31.102 */
static const int ef_usim_files[] = {
    0x6F05, 0x6F06, 0x6F07, 0x6F08, 0x6F09,
    0x6F2C, 0x6F31, 0x6F32, 0x6F37, 0x6F38,
    0x6F39, 0x6F3B, 0x6F3C, 0x6F3E, 0x6F3F,
    0x6F40, 0x6F41, 0x6F42, 0x6F43, 0x6F45,
    0x6F46, 0x6F47, 0x6F48, 0x6F49, 0x6F4B,
    0x6F4C, 0x6F4D, 0x6F4E, 0x6F4F, 0x6F50,
    0x6F55, 0x6F56, 0x6F57, 0x6F58, 0x6F5B,
    0x6F5C, 0x6F60, 0x6F61, 0x6F62, 0x6F73,
    0x6F78, 0x6F7B, 0x6F7E, 0x6F80, 0x6F81,
    0x6F82, 0x6F83, 0x6FAD, 0x6FB1, 0x6FB2,
    0x6FB3, 0x6FB4, 0x6FB5, 0x6FB6, 0x6FB7,
    0x6FC3, 0x6FC4, 0x6FC5, 0x6FC6, 0x6FC7,
    0x6FC8, 0x6FC9, 0x6FCA, 0x6FCB, 0x6FCC,
    0x6FCD, 0x6FCE, 0x6FCF, 0x6FD0, 0x6FD1,
    0x6FD2, 0x6FD3, 0x6FD4, 0x6FD5, 0x6FD6,
    0x6FD7, 0x6FD8, 0x6FD9, 0x6FDA, 0x6FDB,
};

static const int ef_telecom_files[] = {
    0x6F3A, 0x6F3D, 0x6F44, 0x6F4A, 0x6F54,
};

#define PATH_ADF_USIM_DIRECTORY      "3F007FFF"
#define PATH_ADF_TELECOM_DIRECTORY   "3F007F10"

/* RID: A000000087 = 3GPP, PIX: 1002 = 3GPP USIM */
#define USIM_APPLICATION_ID          "A0000000871002"

static int s_simResetting = 0;
static int s_simRemoved = 0;

int get_pending_hotswap(void)
{
    return sim_hotswap;
}

void set_pending_hotswap(int pending_hotswap)
{
    sim_hotswap = pending_hotswap;
}

void onSimStateChanged(const char *s)
{
    int state;
    char *tok = NULL;
    char *line = NULL;

    /* let the status from EESIMSWAP override
     * that of ESIMSR
     */
    if (s_simRemoved)
        return;

    line = tok = strdup(s);

    if (NULL == line) {
        ALOGE("%s() failed to allocate memory!", __func__);
        return;
    }

    if (at_tok_start(&line) < 0)
        goto error;

    if (at_tok_nextint(&line, &state) < 0)
        goto error;

    /*
     * s_simResetting is used to coordinate state changes during sim resetting,
     * i.e. ESIMSR state changing from 7 to 4 or 5.
     */
    switch (state) {
    case 7: /* SIM STATE POWER OFF, or indicating no SIM inserted. */
        s_simResetting = 1;
        setRadioState(RADIO_STATE_SIM_LOCKED_OR_ABSENT);
        break;
    case 4: /* SIM STATE WAIT FOR PIN */
        if (s_simResetting) {
            s_simResetting = 0;
            /*
             * Android will not poll for SIM state if Radio State has no
             * changes. Therefore setRadioState twice to make Android poll for
             * Sim state when there is a PIN state change.
             */
            setRadioState(RADIO_STATE_SIM_NOT_READY);
            setRadioState(RADIO_STATE_SIM_LOCKED_OR_ABSENT);
        }
        break;
    case 5: /* SIM STATE ACTIVE */
        if (s_simResetting) {
            s_simResetting = 0;
            /*
             * Android will not poll for SIM state if Radio State has no
             * changes. Therefore setRadioState twice to make Android poll for
             * Sim state when there is a PIN state change.
             */
            setRadioState(RADIO_STATE_SIM_NOT_READY);
            setRadioState(RADIO_STATE_SIM_READY);
        }
        break;
    case 2: /* SIM STATE BLOCKED */
    case 3: /* SIM STATE BLOCKED FOREVER */
        setRadioState(RADIO_STATE_SIM_LOCKED_OR_ABSENT);
        break;
    default:
        /*
         * s_simResetting should not be changed in the states between SIM POWER
         * OFF to SIM STATE WAIT FOR PIN or SIM STATE ACTIVE.
         */
        break;
    }

    RIL_onUnsolicitedResponse(RIL_UNSOL_RESPONSE_SIM_STATUS_CHANGED, NULL, 0);

finally:
    free(tok);
    return;

error:
    ALOGE("Error in %s", __func__);
    goto finally;
}

void ResetHotswap(void)
{
    s_simRemoved = 0;
}

void onSimHotswap(const char *s)
{
    if (strcmp ("*EESIMSWAP:0", s) == 0) {
        ALOGD("%s() SIM Removed", __func__);
        s_simRemoved = 1;
        /* Toggle radio state since Android won't
         * poll the sim state unless the radio
         * state has changed from the previous
         * value
         */
        setRadioState(RADIO_STATE_SIM_NOT_READY);
        setRadioState(RADIO_STATE_SIM_LOCKED_OR_ABSENT);
        enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, setPollSIMState, (void *) 0, NULL);
    } else if (strcmp ("*EESIMSWAP:1", s) == 0) {
        ALOGD("%s() SIM Inserted", __func__);
        s_simRemoved = 0;
        set_pending_hotswap(1);
        enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, setPollSIMState, (void *) 1, NULL);
    } else
        ALOGD("%s() Unknown SIM Hot Swap Event: %s", __func__, s);
}

/**
 * Get the number of retries left for pin functions
 */
static int getNumRetries (int request) {
    ATResponse *atresponse = NULL;
    int err;
    int num_retries = -1;

    err = at_send_command_singleline("AT*EPIN?", "*EPIN:", &atresponse);
    if (err != AT_NOERROR) {
        ALOGE("%s() AT*EPIN error", __func__);
        return -1;
    }

    switch (request) {
    case RIL_REQUEST_ENTER_SIM_PIN:
    case RIL_REQUEST_CHANGE_SIM_PIN:
        sscanf(atresponse->p_intermediates->line, "*EPIN: %d",
               &num_retries);
        break;
    case RIL_REQUEST_ENTER_SIM_PUK:
        sscanf(atresponse->p_intermediates->line, "*EPIN: %*d,%d",
               &num_retries);
        break;
    case RIL_REQUEST_ENTER_SIM_PIN2:
    case RIL_REQUEST_CHANGE_SIM_PIN2:
        sscanf(atresponse->p_intermediates->line, "*EPIN: %*d,%*d,%d",
               &num_retries);
        break;
    case RIL_REQUEST_ENTER_SIM_PUK2:
        sscanf(atresponse->p_intermediates->line, "*EPIN: %*d,%*d,%*d,%d",
               &num_retries);
        break;
    default:
        num_retries = -1;
    break;
    }

    at_response_free(atresponse);
    return num_retries;
}

/** Returns one of SIM_*. Returns SIM_NOT_READY on error. */
static SIM_Status getSIMStatus(void)
{
    ATResponse *atresponse = NULL;
    int err;
    SIM_Status ret = SIM_ABSENT;
    char *cpinLine;
    char *cpinResult;

    if (s_simRemoved)
        return SIM_ABSENT;

    if (getRadioState() == RADIO_STATE_OFF ||
        getRadioState() == RADIO_STATE_UNAVAILABLE) {
        return SIM_NOT_READY;
    }

    err = at_send_command_singleline("AT+CPIN?", "+CPIN:", &atresponse);

    if (err != AT_NOERROR) {
        if (at_get_error_type(err) == AT_ERROR)
            return SIM_NOT_READY;

        switch (at_get_cme_error(err)) {
        case CME_SIM_NOT_INSERTED:
            ret = SIM_ABSENT;
            break;
        case CME_SIM_PIN_REQUIRED:
            ret = SIM_PIN;
            break;
        case CME_SIM_PUK_REQUIRED:
            ret = SIM_PUK;
            break;
        case CME_SIM_PIN2_REQUIRED:
            ret = SIM_PIN2;
            break;
        case CME_SIM_PUK2_REQUIRED:
            ret = SIM_PUK2;
            break;
        case CME_NETWORK_PERSONALIZATION_PIN_REQUIRED:
            ret = SIM_NETWORK_PERSO;
            break;
        case CME_NETWORK_PERSONALIZATION_PUK_REQUIRED:
            ret = SIM_NETWORK_PERSO_PUK;
            break;
        case CME_NETWORK_SUBSET_PERSONALIZATION_PIN_REQUIRED:
            ret = SIM_NETWORK_SUBSET_PERSO;
            break;
        case CME_NETWORK_SUBSET_PERSONALIZATION_PUK_REQUIRED:
            ret = SIM_NETWORK_SUBSET_PERSO_PUK;
            break;
        case CME_SERVICE_PROVIDER_PERSONALIZATION_PIN_REQUIRED:
            ret = SIM_SERVICE_PROVIDER_PERSO;
            break;
        case CME_SERVICE_PROVIDER_PERSONALIZATION_PUK_REQUIRED:
            ret = SIM_SERVICE_PROVIDER_PERSO_PUK;
            break;
        case CME_PH_SIMLOCK_PIN_REQUIRED: /* PUK not in use by modem */
            ret = SIM_SIM_PERSO;
            break;
        case CME_CORPORATE_PERSONALIZATION_PIN_REQUIRED:
            ret = SIM_CORPORATE_PERSO;
            break;
        case CME_CORPORATE_PERSONALIZATION_PUK_REQUIRED:
            ret = SIM_CORPORATE_PERSO_PUK;
            break;
        default:
            ret = SIM_NOT_READY;
            break;
        }
        return ret;
    }

    /* CPIN? has succeeded, now look at the result. */

    cpinLine = atresponse->p_intermediates->line;
    err = at_tok_start(&cpinLine);

    if (err < 0) {
        ret = SIM_NOT_READY;
        goto done;
    }

    err = at_tok_nextstr(&cpinLine, &cpinResult);

    if (err < 0) {
        ret = SIM_NOT_READY;
        goto done;
    }

    if (0 == strcmp(cpinResult, "READY")) {
        ret = SIM_READY;
    } else if (0 == strcmp(cpinResult, "SIM PIN")) {
        ret = SIM_PIN;
    } else if (0 == strcmp(cpinResult, "SIM PUK")) {
        ret = SIM_PUK;
    } else if (0 == strcmp(cpinResult, "SIM PIN2")) {
        ret = SIM_PIN2;
    } else if (0 == strcmp(cpinResult, "SIM PUK2")) {
        ret = SIM_PUK2;
    } else if (0 == strcmp(cpinResult, "PH-NET PIN")) {
        ret = SIM_NETWORK_PERSO;
    } else if (0 == strcmp(cpinResult, "PH-NETSUB PIN")) {
        ret = SIM_NETWORK_SUBSET_PERSO;
    } else if (0 == strcmp(cpinResult, "PH-SP PIN")) {
        ret = SIM_SERVICE_PROVIDER_PERSO;
    } else if (0 == strcmp(cpinResult, "PH-CORP PIN")) {
        ret = SIM_CORPORATE_PERSO;
    } else if (0 == strcmp(cpinResult, "PH-SIMLOCK PIN")) {
        ret = SIM_SIM_PERSO;
    } else if (0 == strcmp(cpinResult, "PH-ESL PIN")) {
        ret = SIM_STERICSSON_LOCK;
    } else if (0 == strcmp(cpinResult, "BLOCKED")) {
        int numRetries = getNumRetries(RIL_REQUEST_ENTER_SIM_PUK);
        if (numRetries == -1 || numRetries == 0)
            ret = SIM_PERM_BLOCKED;
        else
            ret = SIM_PUK2_PERM_BLOCKED;
    } else if (0 == strcmp(cpinResult, "PH-SIM PIN")) {
        /*
         * Should not happen since lock must first be set from the phone.
         * Setting this lock is not supported by Android.
         */
        ret = SIM_BLOCKED;
    } else {
        /* Unknown locks should not exist. Defaulting to "sim absent" */
        ret = SIM_ABSENT;
    }
done:
    at_response_free(atresponse);
    return ret;
}

/**
 * Fetch information about UICC card type (SIM/USIM)
 *
 * \return UICC_Type: type of UICC card.
 */
static UICC_Type getUICCType(void)
{
    ATResponse *atresponse = NULL;
    static UICC_Type UiccType = UICC_TYPE_UNKNOWN;
    int err;

    if (getRadioState() == RADIO_STATE_OFF ||
        getRadioState() == RADIO_STATE_UNAVAILABLE) {
        return UICC_TYPE_UNKNOWN;
    }

    if (UiccType == UICC_TYPE_UNKNOWN) {
        err = at_send_command_singleline("AT+CUAD", "+CUAD:", &atresponse);
        if (err == AT_NOERROR) {
            /* USIM */
            if(strstr(atresponse->p_intermediates->line, USIM_APPLICATION_ID)){
                UiccType = UICC_TYPE_USIM;
                ALOGI("Detected card type USIM - stored");
            } else {
                /* should maybe be unknown */
                UiccType = UICC_TYPE_SIM;
            }
        } else if (at_get_error_type(err) != AT_ERROR) {
            /* Command failed - unknown card */
            UiccType = UICC_TYPE_UNKNOWN;
            ALOGE("%s() Failed to detect card type - Retry at next request", __func__);
        } else {
            /* Legacy SIM */
            /* TODO: CUAD only responds OK if SIM is inserted.
             *       This is an inccorect AT response...
             */
            UiccType = UICC_TYPE_SIM;
            ALOGI("Detected card type Legacy SIM - stored");
        }
        at_response_free(atresponse);
    }

    return UiccType;
}


/**
 * Get the current card status.
 *
 * This must be freed using freeCardStatus.
 * @return: On success returns RIL_E_SUCCESS.
 */
static int getCardStatus(RIL_CardStatus_v6 **pp_card_status) {
    RIL_CardState card_state;
    int num_apps;

    SIM_Status sim_status = getSIMStatus();
    if (sim_status == SIM_ABSENT) {
        card_state = RIL_CARDSTATE_ABSENT;
        num_apps = 0;
    } else {
        card_state = RIL_CARDSTATE_PRESENT;
        num_apps = 1;
    }

    /* Allocate and initialize base card status. */
    RIL_CardStatus_v6 *p_card_status = malloc(sizeof(RIL_CardStatus_v6));
    p_card_status->card_state = card_state;
    p_card_status->universal_pin_state = RIL_PINSTATE_UNKNOWN;
    p_card_status->gsm_umts_subscription_app_index = -1;
    p_card_status->cdma_subscription_app_index = -1;
    p_card_status->num_applications = num_apps;

    /* Initialize application status. */
    int i;
    for (i = 0; i < RIL_CARD_MAX_APPS; i++)
        p_card_status->applications[i] = app_status_array[SIM_ABSENT];

    /* Pickup the appropriate application status
       that reflects sim_status for gsm. */
    if (num_apps != 0) {
        UICC_Type uicc_type = getUICCType();

        /* Only support one app, gsm/wcdma. */
        p_card_status->num_applications = 1;
        p_card_status->gsm_umts_subscription_app_index = 0;

        /* Get the correct app status. */
        p_card_status->applications[0] = app_status_array[sim_status];
        if (uicc_type == UICC_TYPE_SIM)
            ALOGI("[Card type discovery]: Legacy SIM");
        else { /* defaulting to USIM */
            ALOGI("[Card type discovery]: USIM");
            p_card_status->applications[0].app_type = RIL_APPTYPE_USIM;
        }
    }

    *pp_card_status = p_card_status;
    return RIL_E_SUCCESS;
}

/**
 * Free the card status returned by getCardStatus.
 */
static void freeCardStatus(RIL_CardStatus_v6 *p_card_status) {
    free(p_card_status);
}

/* Subscribe to SIM State Reporting.
 *   Enable SIM state reporting on the format *ESIMSR: <sim_state>
 */
void setPollSIMState(void *param)
{
    static int enabled = 0;

    if (((int) param == 1) && (enabled == 0)) {
        at_send_command("AT*ESIMSR=1");
        enabled = 1;
        ALOGD("%s() Enabled SIM status reporting", __func__);
    } else if (((int) param == 0) && (enabled == 1)) {
        at_send_command("AT*ESIMSR=0");
        enabled = 0;
        ALOGD("%s() Disabled SIM status reporting", __func__);
    }
}

/**
 * SIM ready means any commands that access the SIM will work, including:
 *  AT+CPIN, AT+CSMS, AT+CNMI, AT+CRSM
 *  (all SMS-related commands).
 */
void pollSIMState(void *param)
{
    if (((int) param) != 1 &&
        getRadioState() != RADIO_STATE_SIM_NOT_READY &&
        getRadioState() != RADIO_STATE_SIM_LOCKED_OR_ABSENT)
        /* No longer valid to poll. */
        return;

    switch (getSIMStatus()) {
    case SIM_NOT_READY:
        ALOGI("SIM_NOT_READY, poll for sim state.");
        enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, pollSIMState, NULL,
                        &TIMEVAL_SIMPOLL);
        return;

    case SIM_PIN2:
    case SIM_PUK2:
    case SIM_PUK2_PERM_BLOCKED:
    case SIM_READY:
        setRadioState(RADIO_STATE_SIM_READY);
        enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, setPollSIMState, (void *) 1, NULL);
        return;
    case SIM_ABSENT:
        setRadioState(RADIO_STATE_SIM_LOCKED_OR_ABSENT);
        enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, setPollSIMState, (void *) 0, NULL);
        return;
    case SIM_PIN:
    case SIM_PUK:
    case SIM_NETWORK_PERSO:
    case SIM_NETWORK_SUBSET_PERSO:
    case SIM_SERVICE_PROVIDER_PERSO:
    case SIM_CORPORATE_PERSO:
    case SIM_SIM_PERSO:
    case SIM_STERICSSON_LOCK:
    case SIM_BLOCKED:
    case SIM_PERM_BLOCKED:
    case SIM_NETWORK_PERSO_PUK:
    case SIM_NETWORK_SUBSET_PERSO_PUK:
    case SIM_SERVICE_PROVIDER_PERSO_PUK:
    case SIM_CORPORATE_PERSO_PUK:
    /* pass through, do not break */
    default:
        setRadioState(RADIO_STATE_SIM_LOCKED_OR_ABSENT);
        enqueueRILEvent(RIL_EVENT_QUEUE_PRIO, setPollSIMState, (void *) 1, NULL);
        return;
    }
}

/**
 * RIL_REQUEST_GET_SIM_STATUS
 *
 * Requests status of the SIM interface and the SIM card.
 *
 * Valid errors:
 *  Must never fail.
 */
void requestGetSimStatus(void *data, size_t datalen, RIL_Token t)
{
    (void) data; (void) datalen;
    RIL_CardStatus_v6* p_card_status = NULL;

    if (getCardStatus(&p_card_status) != RIL_E_SUCCESS)
        goto error;

    RIL_onRequestComplete(t, RIL_E_SUCCESS, (char*)p_card_status, sizeof(*p_card_status));

finally:
    if (p_card_status != NULL)
        freeCardStatus(p_card_status);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    goto finally;
}

static int simIOGetLogicalChannel(void)
{
    ATResponse *atresponse = NULL;
    static int g_lc = 0;
    int err;

    if (g_lc == 0) {
        struct tlv tlvApp, tlvAppId;
        char *line;
        char *resp;

        err = at_send_command_singleline("AT+CUAD", "+CUAD:", &atresponse);
        if (err != AT_NOERROR)
            return g_lc;

        line = atresponse->p_intermediates->line;
        err = at_tok_start(&line);
        if (err < 0)
            goto finally;

        err = at_tok_nextstr(&line, &resp);
        if (err < 0)
            goto finally;

        err = parseTlv(resp, &resp[strlen(resp)], &tlvApp);
        if (err < 0)
            goto finally;
        if (tlvApp.tag != 0x61) { /* Application */
            err = -EINVAL;
            goto finally;
        }

        err = parseTlv(tlvApp.data, tlvApp.end, &tlvAppId);
        if (err < 0)
            goto finally;
        if (tlvAppId.tag != 0x4F) { /* Application ID */
            err = -EINVAL;
            goto finally;
        }

        at_response_free(atresponse);
        err = at_send_command_singleline("AT+CCHO=\"%.*s\"", "+CCHO:", &atresponse, tlvAppId.end - tlvAppId.data, tlvAppId.data);
        if (err != AT_NOERROR)
            return g_lc;
        line = atresponse->p_intermediates->line;
        err = at_tok_start(&line);
        if (err < 0)
            goto finally;

        err = at_tok_nextint(&line, &g_lc);
        if (err < 0)
            goto finally;
    }

finally:
    at_response_free(atresponse);
    return g_lc;
}

static int simIOSelectFile(unsigned short fileid)
{
    int err = 0;
    unsigned short lc = simIOGetLogicalChannel();
    ATResponse *atresponse = NULL;
    char *line;
    char *resp;
    int resplen;

    if (lc == 0)
        return -EIO;

    err = at_send_command_singleline("AT+CGLA=%d,14,\"00A4000C02%.4X\"", "+CGLA:", &atresponse, lc, fileid);
    if (at_get_error_type(err) == AT_ERROR)
        return err;
    if (err != AT_NOERROR)
        return -EINVAL;

    line = atresponse->p_intermediates->line;
    err = at_tok_start(&line);
    if (err < 0)
        goto finally;

    err = at_tok_nextint(&line, &resplen);
    if (err < 0)
        goto finally;

    err = at_tok_nextstr(&line, &resp);
    if (err < 0)
        goto finally;

    /* Std resp code: "9000" */
    if (resplen != 4 || strcmp(resp, "9000") != 0) {
        err = -EIO;
        goto finally;
    }

finally:
    at_response_free(atresponse);
    return err;
}

static int simIOSelectPath(const char *path, unsigned short fileid)
{
    int err = 0;
    size_t path_len = 0;
    size_t pos;
    static char cashed_path[4 * 10 + 1] = {'\0'};
    static unsigned short cashed_fileid = 0;

    if (path == NULL)
        path = "3F00";

    path_len = strlen(path);

    if (path_len & 3)
        return -EINVAL;

    if ((fileid != cashed_fileid) || (strcmp(path, cashed_path) != 0)) {
        for(pos = 0; pos < path_len; pos += 4) {
            unsigned val;

            if(sscanf(&path[pos], "%4X", &val) != 1)
                return -EINVAL;

            err = simIOSelectFile(val);
            if (err < 0)
                return err;
        }
        err = simIOSelectFile(fileid);
    }
    if (path_len < sizeof(cashed_path)) {
        strcpy(cashed_path, path);
        cashed_fileid = fileid;
    } else {
        cashed_path[0] = '\0';
        cashed_fileid = 0;
    }
    return err;
}

int sendSimIOCmdUICC(const RIL_SIM_IO_v6 *ioargs, ATResponse **atresponse, RIL_SIM_IO_Response *sr)
{
    int err;
    int resplen;
    char *line, *resp;
    char *data = NULL;
    unsigned short lc = simIOGetLogicalChannel();
    unsigned char sw1, sw2;

    if (lc == 0)
        return -EIO;

    memset(sr, 0, sizeof(*sr));

    switch (ioargs->command) {
        case 0xC0: /* Get response */
            /* Convert Get response to Select. */
            asprintf(&data, "00A4000402%.4X00",
                ioargs->fileid);
            break;

        case 0xB0: /* Read binary */
        case 0xB2: /* Read record */
            asprintf(&data, "00%.2X%.2X%.2X%.2X",
                (unsigned char)ioargs->command,
                (unsigned char)ioargs->p1,
                (unsigned char)ioargs->p2,
                (unsigned char)ioargs->p3);
            break;

        case 0xD6: /* Update binary */
        case 0xDC: /* Update record */
            if (!ioargs->data) {
                err = -EINVAL;
                goto finally;
            }
            asprintf(&data, "00%.2X%.2X%.2X%.2X%s",
                (unsigned char)ioargs->command,
                (unsigned char)ioargs->p1,
                (unsigned char)ioargs->p2,
                (unsigned char)ioargs->p3,
                ioargs->data);
            break;

        default:
            return -ENOTSUP;
    }
    if (data == NULL) {
        err = -ENOMEM;
        goto finally;
    }

    err = simIOSelectPath(ioargs->path, ioargs->fileid);
    if (err < 0)
        goto finally;

    err = at_send_command_singleline("AT+CGLA=%d,%d,\"%s\"", "+CGLA:", atresponse, lc, strlen(data), data);
    if (err != AT_NOERROR)
        goto finally;

    line = (*atresponse)->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto finally;

    err = at_tok_nextint(&line, &resplen);
    if (err < 0)
        goto finally;

    err = at_tok_nextstr(&line, &resp);
    if (err < 0)
        goto finally;

    if ((resplen < 4) || ((size_t)resplen != strlen(resp))) {
        err = -EINVAL;
        goto finally;
    }

    err = stringToBinary(&resp[resplen - 4], 2, &sw1);
    if (err < 0)
        goto finally;

    err = stringToBinary(&resp[resplen - 2], 2, &sw2);
    if (err < 0)
        goto finally;

    sr->sw1 = sw1;
    sr->sw2 = sw2;
    resp[resplen - 4] = 0;
    sr->simResponse = resp;

finally:
    free(data);
    return err;
}


int sendSimIOCmdICC(const RIL_SIM_IO_v6 *ioargs, ATResponse **atresponse, RIL_SIM_IO_Response *sr)
{
    int err;
    char *fmt;
    char *arg6;
    char *arg7;
    char *line;

    /* FIXME Handle pin2. */
    memset(sr, 0, sizeof(*sr));

    arg6 = ioargs->data;
    arg7 = ioargs->path;

    if (arg7 && arg6) {
        fmt = "AT+CRSM=%d,%d,%d,%d,%d,\"%s\",\"%s\"";
    } else if (arg7) {
        fmt = "AT+CRSM=%d,%d,%d,%d,%d,,\"%s\"";
        arg6 = arg7;
    } else if (arg6) {
        fmt = "AT+CRSM=%d,%d,%d,%d,%d,\"%s\"";
    } else {
        fmt = "AT+CRSM=%d,%d,%d,%d,%d";
    }

    err = at_send_command_singleline(fmt, "+CRSM:", atresponse,ioargs->command,
                 ioargs->fileid, ioargs->p1,
                 ioargs->p2, ioargs->p3,
                 arg6, arg7);

    if (err != AT_NOERROR)
        return err;

    line = (*atresponse)->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto finally;

    err = at_tok_nextint(&line, &(sr->sw1));
    if (err < 0)
        goto finally;

    err = at_tok_nextint(&line, &(sr->sw2));
    if (err < 0)
        goto finally;

    if (at_tok_hasmore(&line)) {
        err = at_tok_nextstr(&line, &(sr->simResponse));
        if (err < 0)
            goto finally;
    }

finally:
    return err;
}

static int sendSimIOCmd(const RIL_SIM_IO_v6 *ioargs, ATResponse **atresponse, RIL_SIM_IO_Response *sr)
{
    int err;
    UICC_Type UiccType;

    if (sr == NULL)
        return -1;

    /* Detect card type to determine which SIM access command to use */
    UiccType = getUICCType();

    /*
     * FIXME WORKAROUND: Currently GCLA works from some files on some cards
     * and CRSM works on some files for some cards...
     * Trying with CRSM first and retry with CGLA if needed
     */
    err = sendSimIOCmdICC(ioargs, atresponse, sr);
    if ((err < 0 || (sr->sw1 != 0x90 && sr->sw2 != 0x00)) &&
            UiccType != UICC_TYPE_SIM) {
        at_response_free(*atresponse);
        *atresponse = NULL;
        ALOGD("%s() Retrying with CGLA access...", __func__);
        err = sendSimIOCmdUICC(ioargs, atresponse, sr);
    }
    /* END WORKAROUND */

    /* reintroduce below code when workaround is not needed */
    /* if (UiccType == UICC_TYPE_SIM)
        err = sendSimIOCmdICC(ioargs, atresponse, sr);
    else {
        err = sendSimIOCmdUICC(ioargs, atresponse, sr);
    } */

    return err;
}

static int convertSimIoFcp(RIL_SIM_IO_Response *sr, char **cvt)
{
    int err;
    /* size_t pos; */
    size_t fcplen;
    struct ts_51011_921_resp resp;
    void *cvt_buf = NULL;

    if (!sr->simResponse || !cvt) {
        err = -EINVAL;
        goto error;
    }

    fcplen = strlen(sr->simResponse);
    if ((fcplen == 0) || (fcplen & 1)) {
        err = -EINVAL;
        goto error;
    }

    err = fcp_to_ts_51011(sr->simResponse, fcplen, &resp);
    if (err < 0)
        goto error;

    cvt_buf = malloc(sizeof(resp) * 2 + 1);
    if (!cvt_buf) {
        err = -ENOMEM;
        goto error;
    }

    err = binaryToString((unsigned char*)(&resp),
                   sizeof(resp), cvt_buf);
    if (err < 0)
        goto error;

    /* cvt_buf ownership is moved to the caller */
    *cvt = cvt_buf;
    cvt_buf = NULL;

finally:
    return err;

error:
    free(cvt_buf);
    goto finally;
}


/**
 * RIL_REQUEST_SIM_IO
 *
 * Request SIM I/O operation.
 * This is similar to the TS 27.007 "restricted SIM" operation
 * where it assumes all of the EF selection will be done by the
 * callee.
 */
void requestSIM_IO(void *data, size_t datalen, RIL_Token t)
{
    (void) datalen;
    ATResponse *atresponse = NULL;
    RIL_SIM_IO_Response sr;
    int cvt_done = 0;
    int err;
    UICC_Type UiccType = getUICCType();

    int pathReplaced = 0;
    RIL_SIM_IO_v6 ioargsDup;

    /*
     * Android telephony framework does not support USIM cards properly,
     * send GSM filepath where as active cardtype is USIM.
     * Android RIL needs to change the file path of files listed under ADF-USIM
     * if current active cardtype is USIM
     */
    memcpy(&ioargsDup, data, sizeof(RIL_SIM_IO_v6));
    if (UICC_TYPE_USIM == UiccType) {
        unsigned int i;
        int err;
        unsigned int count = sizeof(ef_usim_files) / sizeof(int);

        for (i = 0; i < count; i++) {
            if (ef_usim_files[i] == ioargsDup.fileid) {
                err = asprintf(&ioargsDup.path, PATH_ADF_USIM_DIRECTORY);
                if (err < 0)
                    goto error;
                pathReplaced = 1;
                ALOGD("%s() Path replaced for USIM: %d", __func__, ioargsDup.fileid);
                break;
            }
        }
        if(!pathReplaced){
            unsigned int count2 = sizeof(ef_telecom_files) / sizeof(int);
            for (i = 0; i < count2; i++) {
                if (ef_telecom_files[i] == ioargsDup.fileid) {
                    err = asprintf(&ioargsDup.path, PATH_ADF_TELECOM_DIRECTORY);
                    if (err < 0)
                        goto error;
                    pathReplaced = 1;
                    ALOGD("%s() Path replaced for telecom: %d", __func__, ioargsDup.fileid);
                    break;
                }
            }
        }
    }

    memset(&sr, 0, sizeof(sr));

    err = sendSimIOCmd(&ioargsDup, &atresponse, &sr);

    if (err < 0)
        goto error;

    /*
     * In case the command is GET_RESPONSE and cardtype is 3G SIM
     * convert to 2G FCP
     */
    if (ioargsDup.command == 0xC0 && UiccType != UICC_TYPE_SIM) {
        err = convertSimIoFcp(&sr, &sr.simResponse);
        if (err < 0)
            goto error;
        cvt_done = 1; /* sr.simResponse needs to be freed */
    }

    RIL_onRequestComplete(t, RIL_E_SUCCESS, &sr, sizeof(sr));

finally:
    at_response_free(atresponse);
    if (cvt_done)
        free(sr.simResponse);

    if (pathReplaced)
        free(ioargsDup.path);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    goto finally;
}

/**
 * Enter SIM PIN, might be PIN, PIN2, PUK, PUK2, etc.
 *
 * Data can hold pointers to one or two strings, depending on what we
 * want to enter. (PUK requires new PIN, etc.).
 *
 * FIXME: Do we need to return remaining tries left on error as well?
 *        Also applies to the rest of the requests that got the retries
 *        in later commits to ril.h.
 */
void requestEnterSimPin(void *data, size_t datalen, RIL_Token t, int request)
{
    int err = 0;
    int cme_err;
    const char **strings = (const char **) data;
    int num_retries = -1;

    if (datalen == sizeof(char *)) {
        err = at_send_command("AT+CPIN=\"%s\"", strings[0]);
    } else if (datalen == 2 * sizeof(char *)) {
        if(!strings[1]){
            err = at_send_command("AT+CPIN=\"%s\"", strings[0]);
        } else {
            err = at_send_command("AT+CPIN=\"%s\",\"%s\"", strings[0], strings[1]);
        }
    } else if (datalen == 3 * sizeof(char *)) {
            err = at_send_command("AT+CPIN=\"%s\",\"%s\"", strings[0], strings[1]);
    } else
        goto error;

    cme_err = at_get_cme_error(err);

    if (cme_err != CME_ERROR_NON_CME && err != AT_NOERROR) {
        switch (cme_err) {
        case CME_SIM_PIN_REQUIRED:
        case CME_SIM_PUK_REQUIRED:
        case CME_INCORRECT_PASSWORD:
        case CME_SIM_PIN2_REQUIRED:
        case CME_SIM_PUK2_REQUIRED:
            num_retries = getNumRetries (request);
            RIL_onRequestComplete(t, RIL_E_PASSWORD_INCORRECT, &num_retries, sizeof(int *));
            break;
        default:
            goto error;
        }
    } else {
        /*
         * Got OK, return success and wait for *EPEV to trigger poll
         * of SIM state.
         */

        num_retries = getNumRetries (request);
        RIL_onRequestComplete(t, RIL_E_SUCCESS, &num_retries, sizeof(int *));
    }
    return;
error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
}

void requestChangePassword(void *data, size_t datalen, RIL_Token t,
                           char *facility, int request)
{
    int err = 0;
    char *oldPassword = NULL;
    char *newPassword = NULL;
    int num_retries = -1;

    if (datalen != 3 * sizeof(char *) || strlen(facility) != 2)
        goto error;


    oldPassword = ((char **) data)[0];
    newPassword = ((char **) data)[1];

    err = at_send_command("AT+CPWD=\"%s\",\"%s\",\"%s\"", facility,
                oldPassword, newPassword);
    if (err != AT_NOERROR)
        goto error;

    num_retries = getNumRetries(request);
    RIL_onRequestComplete(t, RIL_E_SUCCESS, &num_retries, sizeof(int *));

    return;

error:
    if (at_get_cme_error(err) == CME_INCORRECT_PASSWORD) {
        num_retries = getNumRetries(request);
        RIL_onRequestComplete(t, RIL_E_PASSWORD_INCORRECT, &num_retries, sizeof(int *));
    } else
        RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
}

/**
 * RIL_REQUEST_SET_FACILITY_LOCK
 *
 * Enable/disable one facility lock.
 */
void requestSetFacilityLock(void *data, size_t datalen, RIL_Token t)
{
    int err;
    char *facility_string = NULL;
    int facility_mode = -1;
    char *facility_mode_str = NULL;
    char *facility_password = NULL;
    char *facility_class = NULL;
    int num_retries = -1;
    RIL_Errno errorril = RIL_E_GENERIC_FAILURE;
    (void) datalen;

    if (datalen < 4 * sizeof(char **)) {
        ALOGE("%s() bad data length!", __func__);
        goto exit;
    }

    facility_string = ((char **) data)[0];
    facility_mode_str = ((char **) data)[1];
    facility_password = ((char **) data)[2];
    facility_class = ((char **) data)[3];

    if (*facility_mode_str != '0' && *facility_mode_str != '1') {
        ALOGE("%s() bad facility mode!", __func__);
        goto exit;
    }

    facility_mode = atoi(facility_mode_str);

    /*
     * Skip adding facility_password to AT command parameters if it is NULL,
     * printing NULL with %s will give string "(null)".
     */
    err = at_send_command("AT+CLCK=\"%s\",%d,\"%s\",%s", facility_string,
            facility_mode, facility_password, facility_class);

    if (at_get_error_type(err) == AT_ERROR)
        goto exit;
    if (err != AT_NOERROR) {
        switch (at_get_cme_error(err)) {
        /* CME ERROR 11: "SIM PIN required" happens when PIN is wrong */
        case CME_SIM_PIN_REQUIRED:
            ALOGI("Wrong PIN");
            errorril = RIL_E_PASSWORD_INCORRECT;
            break;
        /*
         * CME ERROR 12: "SIM PUK required" happens when wrong PIN is used
         * 3 times in a row
         */
        case CME_SIM_PUK_REQUIRED:
            ALOGI("PIN locked, change PIN with PUK");
            num_retries = 0;/* PUK required */
            errorril = RIL_E_PASSWORD_INCORRECT;
            break;
        /* CME ERROR 16: "Incorrect password" happens when PIN is wrong */
        case CME_INCORRECT_PASSWORD:
            ALOGI("Incorrect password, Facility: %s", facility_string);
            errorril = RIL_E_PASSWORD_INCORRECT;
            break;
        /* CME ERROR 17: "SIM PIN2 required" happens when PIN2 is wrong */
        case CME_SIM_PIN2_REQUIRED:
            ALOGI("Wrong PIN2");
            errorril = RIL_E_PASSWORD_INCORRECT;
            break;
        /*
         * CME ERROR 18: "SIM PUK2 required" happens when wrong PIN2 is used
         * 3 times in a row
         */
        case CME_SIM_PUK2_REQUIRED:
            ALOGI("PIN2 locked, change PIN2 with PUK2");
            num_retries = 0;/* PUK2 required */
            errorril = RIL_E_SIM_PUK2;
            break;
        default: /* some other error */
            num_retries = -1;
            break;
        }
        goto finally;
    }

    errorril = RIL_E_SUCCESS;

finally:
    if (strncmp(facility_string, "SC", 2) == 0)
        num_retries = getNumRetries(RIL_REQUEST_ENTER_SIM_PIN);
    else if  (strncmp(facility_string, "FD", 2) == 0)
        num_retries = getNumRetries(RIL_REQUEST_ENTER_SIM_PIN2);
exit:
    RIL_onRequestComplete(t, errorril, &num_retries,  sizeof(int *));
}

/**
 * RIL_REQUEST_QUERY_FACILITY_LOCK
 *
 * Query the status of a facility lock state.
 */
void requestQueryFacilityLock(void *data, size_t datalen, RIL_Token t)
{
    int err, response;
    ATResponse *atresponse = NULL;
    char *line = NULL;
    char *facility_string = NULL;
    char *facility_password = NULL;
    char *facility_class = NULL;

    (void) datalen;

    if (datalen < 3 * sizeof(char **)) {
        ALOGE("%s() bad data length!", __func__);
        goto error;
    }

    facility_string = ((char **) data)[0];
    facility_password = ((char **) data)[1];
    facility_class = ((char **) data)[2];

    err = at_send_command_singleline("AT+CLCK=\"%s\",2,\"%s\",%s", "+CLCK:", &atresponse,
            facility_string, facility_password, facility_class);
    if (err != AT_NOERROR)
        goto error;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);

    if (err < 0)
        goto error;

    err = at_tok_nextint(&line, &response);

    if (err < 0)
        goto error;

    RIL_onRequestComplete(t, RIL_E_SUCCESS, &response, sizeof(int));
    at_response_free(atresponse);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    at_response_free(atresponse);
}
                                                                              u300-ril-sim.h                                                                                      0000644 0001750 0001750 00000003147 12271742740 013133  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2009
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#ifndef U300_RIL_SIM_H
#define U300_RIL_SIM_H 1

int get_pending_hotswap(void);
void set_pending_hotswap(int pending_hotswap);

void onSimStateChanged(const char *s);
void onSimHotswap(const char *s);
void ResetHotswap(void);

void requestGetSimStatus(void *data, size_t datalen, RIL_Token t);
void requestSIM_IO(void *data, size_t datalen, RIL_Token t);
void requestEnterSimPin(void *data, size_t datalen, RIL_Token t, int request);
void requestChangePassword(void *data, size_t datalen, RIL_Token t,
                           char *facility, int request);
void requestSetFacilityLock(void *data, size_t datalen, RIL_Token t);
void requestQueryFacilityLock(void *data, size_t datalen, RIL_Token t);

void pollSIMState(void *param);

void setPollSIMState(void *param);

#endif
                                                                                                                                                                                                                                                                                                                                                                                                                         u300-ril-stk.c                                                                                      0000644 0001750 0001750 00000044246 12271742740 013144  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2010
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
** Author: Sverre Vegge <sverre.vegge@stericsson.com>
*/

#include <stdio.h>
#include <string.h>
#include "atchannel.h"
#include "at_tok.h"
#include "misc.h"
#include <telephony/ril.h>
#include "u300-ril.h"

#define LOG_TAG "RILV"
#include <utils/Log.h>

#define SIM_REFRESH 0x01

enum SimResetMode {
    SAT_SIM_INITIALIZATION_AND_FULL_FILE_CHANGE_NOTIFICATION = 0,
    SAT_FILE_CHANGE_NOTIFICATION = 1,
    SAT_SIM_INITIALIZATION_AND_FILE_CHANGE_NOTIFICATION = 2,
    SAT_SIM_INITIALIZATION = 3,
    SAT_SIM_RESET = 4,
    SAT_NAA_APPLICATION_RESET = 5,
    SAT_NAA_SESSION_RESET = 6,
    SAT_STEERING_OF_ROAMING = 7
};

struct refreshStatus {
    int cmdNumber;
    int cmdQualifier;
    int Result;
};

struct stkmenu {
    size_t len;
    char tag[3];
    char id[3];
    char ct[3];
    char *data;
    char *end;
};

static int stk_service_running = 0;

/**
 * RIL_REQUEST_STK_SEND_TERMINAL_RESPONSE
 *
 * Requests to send a terminal response to SIM for a received
 * proactive command.
 */
void requestStkSendTerminalResponse(void *data, size_t datalen,
                                    RIL_Token t)
{
    int err;
    int rilresponse = RIL_E_SUCCESS;
    (void)datalen;
    const char *stkResponse = (const char *) data;

    err = at_send_command("AT*STKR=\"%s\"", stkResponse);

    if (err != AT_NOERROR)
        rilresponse = RIL_E_GENERIC_FAILURE;

    RIL_onRequestComplete(t, rilresponse, NULL, 0);
}

/**
 * RIL_REQUEST_STK_SEND_ENVELOPE_COMMAND
 *
 * Requests to send a SAT/USAT envelope command to SIM.
 * The SAT/USAT envelope command refers to 3GPP TS 11.14 and 3GPP TS 31.111.
 */
void requestStkSendEnvelopeCommand(void *data, size_t datalen, RIL_Token t)
{
    char *line = NULL;
    char *stkResponse = NULL;
    int err;
    ATResponse *atresponse = NULL;
    const char *ec = (const char *) data;
    (void)datalen;

    err = at_send_command_singleline("AT*STKE=\"%s\"", "*STKE:", &atresponse, ec);

    if (err != AT_NOERROR)
        goto error;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    err = at_tok_nextstr(&line, &stkResponse);
    if (err < 0)
        goto error;

    RIL_onRequestComplete(t, RIL_E_SUCCESS, stkResponse, sizeof(char *));
    at_response_free(atresponse);
    return;

error:
    at_response_free(atresponse);
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
}

/**
 * RIL_REQUEST_STK_GET_PROFILE
 *
 * Requests the profile of SIM tool kit.
 * The profile indicates the SAT/USAT features supported by ME.
 * The SAT/USAT features refer to 3GPP TS 11.14 and 3GPP TS 31.111.
 */
void requestStkGetProfile(void *data, size_t datalen, RIL_Token t)
{
    ATResponse *atresponse = NULL;
    char *line = NULL;
    char *response = NULL;
    int err = 0;
    int skip = 0;
    (void)data;
    (void)datalen;

    err = at_send_command_singleline("AT*STKC?", "*STKC:", &atresponse);

    if (err != AT_NOERROR)
        goto error;

    line = atresponse->p_intermediates->line;

    err = at_tok_start(&line);
    if (err < 0)
        goto error;

    err = at_tok_nextint(&line, &skip);

    if (err < 0)
        goto error;

    err = at_tok_nextstr(&line, &response);
    if (err < 0 || response == NULL)
        goto error;

    RIL_onRequestComplete(t, RIL_E_SUCCESS, response, sizeof(char *));
    at_response_free(atresponse);
    return;

error:
    RIL_onRequestComplete(t, RIL_E_GENERIC_FAILURE, NULL, 0);
    at_response_free(atresponse);
}

int get_stk_service_running(void)
{
    return stk_service_running;
}

void set_stk_service_running(int running)
{
    stk_service_running = running;
}

int init_stk_service(void)
{
    int err;
    int rilresponse = RIL_E_SUCCESS;

    err = at_send_command("AT*STKC=1,\"000000000000000000\"");
    if (err != AT_NOERROR) {
        ALOGE("%s() Failed to activate (U)SAT profile", __func__);
        rilresponse = RIL_E_GENERIC_FAILURE;
    }

    return rilresponse;
}

/**
 * RIL_REQUEST_REPORT_STK_SERVICE_IS_RUNNING
 *
 * Turn on STK unsol commands.
 */
void requestReportStkServiceIsRunning(void *data, size_t datalen, RIL_Token t)
{
    int ret;
    (void)data;
    (void)datalen;

    ret = init_stk_service();

    set_stk_service_running(1);

    RIL_onRequestComplete(t, ret, NULL, 0);
}

/**
 * RIL_REQUEST_STK_SET_PROFILE
 *
 * Download the STK terminal profile as part of SIM initialization
 * procedure.
 */
void requestStkSetProfile(void *data, size_t datalen, RIL_Token t)
{
    int err;
    int rilresponse = RIL_E_SUCCESS;
    const char *profile = (const char *)data;
    (void)datalen;

    err = at_send_command("AT*STKC=0,\"%s\"", profile);

    if (err != AT_NOERROR)
        rilresponse = RIL_E_GENERIC_FAILURE;

    RIL_onRequestComplete(t, rilresponse, NULL, 0);
}

#define ITEM_TAG_SIZE 1
#define PROACT_TAG_SIZE 1
#define LEN_SIZE 1

static char *buildStkMenu(struct stkmenu *cmenu, int n)
{
    char *resp;
    char *p;
    int resplen;
    int lentag;
    int firsttaglen;
    int i;
    char cmd_dts_cmd_id[] = "8103012500" "82028182";

    firsttaglen = sizeof(cmd_dts_cmd_id) - 1;
    lentag = firsttaglen / 2;

    for (i=0; i<=n; i++)
        lentag += ITEM_TAG_SIZE + LEN_SIZE + cmenu[i].len/2;

    resplen = 2 * (lentag + PROACT_TAG_SIZE + 2 * LEN_SIZE) + 1;

    resp = malloc(resplen);

    if (!resp) {
        ALOGD("%s() Memory allocation error", __func__);
        return NULL;
    }

    memset(resp, '\0', resplen);

    p = resp;

    strncpy(p, "D0", 2);
    p += 2;

    if (lentag > 0x7f) {
        sprintf(p,"%02x",0x81);
        p += 2;
    }
    sprintf(p, "%02x", lentag);
    p += 2;

    strncpy(p, cmd_dts_cmd_id, firsttaglen);
    p += firsttaglen;

    for (i=0; i<=n; i++) {
        strcpy(p, cmenu[i].tag);
        p += strlen(cmenu[i].tag);

        snprintf(p, 3, "%02x", cmenu[i].len/2);
        p += 2;

        strcpy(p, cmenu[i].id);
        p += strlen(cmenu[i].id);

        strcpy(p, cmenu[i].ct);
        p += strlen(cmenu[i].ct);

        strncpy(p, cmenu[i].data, cmenu[i].len - strlen(cmenu[i].ct) - strlen(cmenu[i].id));
        p += cmenu[i].len - strlen(cmenu[i].ct) - strlen(cmenu[i].id);
    }

    return resp;
}

void getCachedStkMenu(void)
{
    int id, ct;
    int err;
    int i, n;
    struct stkmenu *pcm;
    struct stkmenu *cmenu = NULL;
    char *line;
    char *p;
    char *resp = NULL;
    ATLine *cursor;
    ATResponse *p_response = NULL;

    err = at_send_command_multiline("AT*ESTKMENU?", "", &p_response);

    if (err != AT_NOERROR)
        return;

    cursor = p_response->p_intermediates;
    line = cursor->line;

    p = strrchr(line, ',');
    if (!p)
        goto cleanup;

    p++;
    n = strtol(p, &p, 10);
    if (n == LONG_MAX || n == LONG_MIN)
        goto cleanup;

    if (n < 0)
        goto cleanup;

    if (n == 0) {
        n = 1;
        cmenu = malloc((n+1)*sizeof(struct stkmenu));
        if (!cmenu) {
            ALOGD("%s() Memory allocation error", __func__);
            goto cleanup;
        }

        memset(cmenu, '\0', sizeof(cmenu));

        for (i = 0; i<=1; i++) {
            pcm = &cmenu[i];
            if (i == 0)
                snprintf(pcm->tag, 3, "85");
            else
                snprintf(pcm->tag, 3, "8F");
            pcm->id[0] = '\0';
            pcm->ct[0] = '\0';
            pcm->data = "";
            pcm->end = pcm->data;
            pcm->len = 0;
        }
    } else {
        cmenu = malloc((n+1)*sizeof(struct stkmenu));
        if (!cmenu) {
            ALOGD("%s() Memory allocation error", __func__);
            goto cleanup;
        }

        memset(cmenu, '\0', sizeof(cmenu));

        pcm = cmenu;

        snprintf(pcm->tag, 3, "85");

        pcm->id[0] = '\0';

        pcm->data = strrchr(line, ' ') + 1;
        if (!pcm->data)
            goto cleanup;

        pcm->end = strchr(line, ',');
        if (!pcm->end)
            goto cleanup;

        line = pcm->end + 1;
        err = at_tok_nextint(&line, &ct);
        if (err < 0)
            goto cleanup;

        if (ct == 0)
            pcm->ct[0] = '\0';
        else if (ct == 1)
            snprintf(pcm->ct, 3, "80");
        else
            goto cleanup;

        pcm->len = pcm->end - pcm->data + strlen(pcm->ct) + strlen(pcm->id);

        for (i = 1; i<=n; i++) {
            cursor = cursor->p_next;
            line = cursor->line;

            pcm = &cmenu[i];

            snprintf(pcm->tag, 3, "8F");

            err = at_tok_nextint(&line, &id);
            if (err < 0)
                goto cleanup;

            snprintf(pcm->id, 3, "%02x", id);

            pcm->data = line;
            pcm->end = strchr(line, ',');
            if (!pcm->end)
                goto cleanup;

            line = pcm->end + 1;
            err = at_tok_nextint(&line, &ct);
            if (err < 0)
                goto cleanup;

            if (ct == 0)
                pcm->ct[0] = '\0';
            else if (ct == 1)
                snprintf(pcm->ct, 3, "80");
            else
                goto cleanup;

            pcm->len = pcm->end - pcm->data + strlen(pcm->ct) + strlen(pcm->id);
        }
    }
    resp = buildStkMenu(cmenu, n);

    if (!resp)
        goto cleanup;

    ALOGD("%s() STKMENU: %s", __func__, resp);
    RIL_onUnsolicitedResponse(RIL_UNSOL_STK_PROACTIVE_COMMAND, resp, sizeof(char *));

cleanup:
    at_response_free(p_response);
    free(cmenu);
    free(resp);
}

static size_t tlv_stream_get(const char **stream, const char *end)
{
    size_t ret;

    if (*stream + 1 >= end)
        return -1;

    ret = ((unsigned)char2nib((*stream)[0]) << 4)
        | ((unsigned)char2nib((*stream)[1]) << 0);
    *stream += 2;

    return ret;
}

static int mbm_parseTlv(const char *stream, const char *end, struct tlv *tlv)
{
    size_t len;

    tlv->tag = tlv_stream_get(&stream, end);
    len = tlv_stream_get(&stream, end);

    /* The length is coded onto 2 or 4 bytes */
    if (len == 0x81)
        len = tlv_stream_get(&stream, end);

    if (stream + 2*len > end)
        return -1;

    tlv->data = &stream[0];
    tlv->end  = &stream[len*2];

    return 0;
}

/**
 * Send TERMINAL RESPONSE after processing REFRESH proactive command
 */
static void sendRefreshTerminalResponse(void *param)
{
    int err;
    struct refreshStatus *refreshState = (struct refreshStatus *)param;

    if (!refreshState)
        ALOGD("%s() called with null parameter", __func__);

    err = at_send_command("AT*STKR=\"8103%02x01%02x820282818301%02x\"",
                   refreshState->cmdNumber, refreshState->cmdQualifier,
                   refreshState->Result);

    free(param);
    refreshState = NULL;

    if (err != AT_NOERROR)
        ALOGD("%s() Failed sending at command", __func__);
}

static uint16_t hex2int(const char *data) {
    uint16_t efid;

    efid = ((unsigned)char2nib(data[0]) << 4)
        | ((unsigned)char2nib(data[1]) << 0);
    efid <<= 8;
    efid |= ((unsigned)char2nib(data[2]) << 4)
        | ((unsigned)char2nib(data[3]) << 0);

    return efid;
}

static void sendSimRefresh(struct tlv *tlvRefreshCmd, char *end)
{
    struct tlv tlvDevId;
    struct tlv tlvFileList;
    const char *devId = tlvRefreshCmd->end;
    int err;
    int response[2];
    unsigned int efid;
    struct refreshStatus *refreshState;

    memset(response,0,sizeof(response));

    refreshState = malloc(sizeof(struct refreshStatus));

    if (!refreshState) {
        ALOGD("%s() Memory allocation error!", __func__);
        return;
    }
    refreshState->cmdNumber = tlv_stream_get(&tlvRefreshCmd->data, tlvRefreshCmd->end);
    /* We don't care about command type */
    tlv_stream_get(&tlvRefreshCmd->data, tlvRefreshCmd->end);

    refreshState->cmdQualifier = tlv_stream_get(&tlvRefreshCmd->data, tlvRefreshCmd->end);

    err = mbm_parseTlv(devId, end, &tlvDevId);

    if ((tlvDevId.tag != 0x82) || (err < 0) || (refreshState->cmdNumber < 0x01) || (refreshState->cmdNumber > 0xFE))
        refreshState->cmdQualifier = -1;

    switch(refreshState->cmdQualifier) {
    case SAT_SIM_INITIALIZATION_AND_FULL_FILE_CHANGE_NOTIFICATION:
    case SAT_SIM_INITIALIZATION_AND_FILE_CHANGE_NOTIFICATION:
    case SAT_SIM_INITIALIZATION:
    case SAT_NAA_APPLICATION_RESET:
        /* SIM initialized.  All files should be re-read. */
        response[0] = SIM_INIT;
        response[1] = 0;
        refreshState->Result = 3; /* success, EFs read */
        break;
    case SAT_SIM_RESET:
        response[0] = SIM_RESET;
        response[1] = 0;
        break;
    case SAT_FILE_CHANGE_NOTIFICATION:
    case SAT_NAA_SESSION_RESET:
        err = mbm_parseTlv(tlvDevId.end, end, &tlvFileList);

        if ((err >= 0) && (tlvFileList.tag == 0x12)) {
            ALOGD("%s() found File List tag", __func__);
            /* one or more files on SIM has been updated
             * but we assume one file for now
             */
            efid = hex2int(tlvFileList.end - 4);
            response[0] = SIM_FILE_UPDATE;
            response[1] = efid;
            refreshState->Result = 3; /* success, EFs read */
            break;
        }
    case SAT_STEERING_OF_ROAMING:
       /* Pass through. Not supported by Android, should never happen */
    default:
        ALOGD("%s() fallback to SIM initialization", __func__);
        /* If parsing of cmdNumber failed, use a number from valid range */
        if (refreshState->cmdNumber < 0)
            refreshState->cmdNumber = 1;
        refreshState->cmdQualifier = SAT_SIM_INITIALIZATION;
        refreshState->Result = 2; /* command performed with missing info */
        response[0] = SIM_INIT;
        response[1] = 0;
        break;
    }

    RIL_onUnsolicitedResponse(RIL_UNSOL_SIM_REFRESH, response, sizeof(response));

    if (response[0] != SIM_RESET) {
        /* AT commands cannot be sent from the at reader thread */
        enqueueRILEvent(RIL_EVENT_QUEUE_NORMAL, sendRefreshTerminalResponse, refreshState, NULL);
    }
}

static int getCmd(char *s, struct tlv *tlvBer, struct tlv *tlvSimple)
{
    int err, cmd = -1;
    char *end = &s[strlen(s)];
    err = mbm_parseTlv(s, end, tlvBer);

    if (err < 0) {
        ALOGD("%s() error parsing BER tlv", __func__);
        return cmd;
    }

    if (tlvBer->tag == 0xD0) {
        ALOGD("%s() Found Proactive SIM command tag", __func__);
        err = mbm_parseTlv(tlvBer->data, tlvBer->end, tlvSimple);
        if (err < 0) {
            ALOGD("%s() error parsing simple tlv", __func__);
            return cmd;
        }

        if (tlvSimple->tag == 0x81) {
            ALOGD("%s() Found command details tag", __func__);
            cmd = ((unsigned)char2nib(tlvSimple->data[2]) << 4)
                | ((unsigned)char2nib(tlvSimple->data[3]) << 0);
        }
    }

    return cmd;
}

static int getStkResponse(char *s, struct tlv *tlvBer, struct tlv *tlvSimple)
{
    int cmd = getCmd(s, tlvBer, tlvSimple);

    switch (cmd){
        case 0x13:
            ALOGD("%s() Send short message", __func__);
            return RIL_UNSOL_STK_EVENT_NOTIFY;
            break;
        case 0x11:
            ALOGD("%s() Send SS", __func__);
            return RIL_UNSOL_STK_EVENT_NOTIFY;
            break;
        case 0x12:
            ALOGD("%s() Send USSD", __func__);
            return RIL_UNSOL_STK_EVENT_NOTIFY;
            break;
        case 0x40:
            ALOGD("%s() Open channel", __func__);
            return RIL_UNSOL_STK_EVENT_NOTIFY;
            break;
        case 0x41:
            ALOGD("%s() Close channel", __func__);
            return RIL_UNSOL_STK_EVENT_NOTIFY;
            break;
        case 0x42:
            ALOGD("%s() Receive data", __func__);
            return RIL_UNSOL_STK_EVENT_NOTIFY;
            break;
        case 0x43:
            ALOGD("%s() Send data", __func__);
            return RIL_UNSOL_STK_EVENT_NOTIFY;
            break;
        case 0x44:
            ALOGD("%s() Get channel status", __func__);
            return RIL_UNSOL_STK_EVENT_NOTIFY;
            break;
        default:
            ALOGD("%s() Proactive command", __func__);
            break;
    }

    return -1;
}

/**
 * RIL_UNSOL_STK_PROACTIVE_COMMAND
 *
 * Indicate when SIM issue a STK proactive command to applications.
 *
 */
void onStkProactiveCommand(const char *s)
{
    char *str = NULL;
    char *line = NULL;
    char *tok = NULL;
    int rilresponse;
    int err;
    struct tlv tlvBer, tlvSimple;

    tok = line = strdup(s);

    if (!tok)
        goto error;

    err = at_tok_start(&tok);
    if (err < 0)
        goto error;

    err = at_tok_nextstr(&tok, &str);
    if (err < 0)
        goto error;

    rilresponse = getStkResponse(str, &tlvBer, &tlvSimple);
    if (rilresponse < 0)
        RIL_onUnsolicitedResponse(RIL_UNSOL_STK_PROACTIVE_COMMAND, str, sizeof(char *));
    else
        RIL_onUnsolicitedResponse(rilresponse, str, sizeof(char *));

    free(line);
    return;

error:
    ALOGE("%s() failed to parse proactive command!", __func__);
    free(line);
}

void onStkEventNotify(const char *s)
{
    char *str = NULL;
    char *line = NULL;
    char *tok = NULL;
    char *end;
    int err;
    struct tlv tlvBer, tlvSimple;
    int cmd;

    tok = line = strdup(s);

    if (!tok)
        goto error;

    err = at_tok_start(&tok);
    if (err < 0)
        goto error;

    err = at_tok_nextstr(&tok, &str);
    if (err < 0)
        goto error;

    cmd = getCmd(str, &tlvBer, &tlvSimple);

    if (cmd == SIM_REFRESH) {
        end = (char *)&str[strlen(str)];
        sendSimRefresh(&tlvSimple, end);
    } else
        RIL_onUnsolicitedResponse(RIL_UNSOL_STK_EVENT_NOTIFY, str, sizeof(char *));

    free(line);
    return;

error:
    ALOGW("%s() Failed to parse STK Notify Event", __func__);
    free(line);
}
                                                                                                                                                                                                                                                                                                                                                          u300-ril-stk.h                                                                                      0000644 0001750 0001750 00000003474 12271742740 013147  0                                                                                                    ustar   borkata                         borkata                                                                                                                                                                                                                /* ST-Ericsson U300 RIL
**
** Copyright (C) ST-Ericsson AB 2008-2010
** Copyright 2006, The Android Open Source Project
**
** Licensed under the Apache License, Version 2.0 (the "License");
** you may not use this file except in compliance with the License.
** You may obtain a copy of the License at
**
**     http://www.apache.org/licenses/LICENSE-2.0
**
** Unless required by applicable law or agreed to in writing, software
** distributed under the License is distributed on an "AS IS" BASIS,
** WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
** See the License for the specific language governing permissions and
** limitations under the License.
**
** Based on reference-ril by The Android Open Source Project.
**
** Heavily modified for ST-Ericsson U300 modems.
** Author: Christian Bejram <christian.bejram@stericsson.com>
*/

#ifndef U300_RIL_STK_H
#define U300_RIL_STK_H 1

int checkAndClear_SIM_NAA_SESSION_RESET(void *param);
void requestStkSendTerminalResponse(void *data, size_t datalen,
                                    RIL_Token t);
void requestStkSendEnvelopeCommand(void *data, size_t datalen,
                                   RIL_Token t);
void requestStkGetProfile(void *data, size_t datalen, RIL_Token t);
void requestReportStkServiceIsRunning(void *data, size_t datalen, RIL_Token t);
void requestStkSetProfile(void *data, size_t datalen, RIL_Token t);
void getCachedStkMenu(void);
void requestStkHandleCallSetupRequestedFromSIM(void *data,
                                               size_t datalen,
                                               RIL_Token t);
void onStkProactiveCommand(const char *s);
void onStkSimRefresh(const char *s);
void onStkEventNotify(const char *s);

int init_stk_service(void);
int get_stk_service_running(void);
void set_stk_service_running(int running);


#endif
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    