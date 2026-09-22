/*
 * Flect — AirPlay receiver for Mac
 * Copyright (C) 2026 Flect contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Wraps UxPlay's raop/dnssd API behind flect_receiver.h. The start-up
 * sequence and feature flags follow uxplay.cpp (start_dnssd,
 * start_raop_server, register_dnssd), with the GStreamer renderers replaced
 * by callbacks into the app.
 *
 * Each device gets its own session (patches/uxplay-multiple-clients.patch):
 * the library calls back with either the receiver (server-wide events) or
 * that device's session, and every callback here accepts both.
 */

#include "flect_receiver.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dnssd.h"
#include "logger.h"
#include "raop.h"

/* The first field of both context kinds, so a callback can tell them apart. */
enum {
    CONTEXT_RECEIVER = 0x46524356,  /* 'FRCV' */
    CONTEXT_SESSION = 0x46534553    /* 'FSES' */
};

typedef struct session {
    uint32_t kind;                  /* CONTEXT_SESSION */
    flect_receiver_t *receiver;
    flect_session_id_t id;
    void *conn;                     /* the library's connection, for disconnecting */
    struct session *next;
} session_t;

struct flect_receiver {
    uint32_t kind;                  /* CONTEXT_RECEIVER */
    flect_callbacks_t callbacks;
    raop_t *raop;
    dnssd_t *dnssd;
    unsigned short port;
    flect_access_t access;
    char *password;
    atomic_int open_connections;

    pthread_mutex_t sessions_lock;  /* guards sessions and next_session_id */
    session_t *sessions;
    flect_session_id_t next_session_id;
};

/* Which receiver a callback belongs to, and which device (0 if none). */
static flect_receiver_t *resolve(void *cls, flect_session_id_t *session) {
    if (*(uint32_t *) cls == CONTEXT_SESSION) {
        session_t *s = cls;
        *session = s->id;
        return s->receiver;
    }
    *session = 0;
    return cls;
}

#define NOTIFY(r, name, ...) \
    do { \
        if ((r)->callbacks.name) { \
            (r)->callbacks.name((r)->callbacks.context, ##__VA_ARGS__); \
        } \
    } while (0)

static void set_error(char *error, size_t error_size, const char *format, ...) {
    if (!error || error_size == 0) {
        return;
    }
    va_list args;
    va_start(args, format);
    vsnprintf(error, error_size, format, args);
    va_end(args);
}

static bool parse_device_id(const char *device_id, unsigned char hw_addr[6]) {
    unsigned int bytes[6];
    if (!device_id || sscanf(device_id, "%2x:%2x:%2x:%2x:%2x:%2x",
                             &bytes[0], &bytes[1], &bytes[2],
                             &bytes[3], &bytes[4], &bytes[5]) != 6) {
        return false;
    }
    for (int i = 0; i < 6; i++) {
        hw_addr[i] = (unsigned char) bytes[i];
    }
    return true;
}

/* ---- sessions (httpd thread) ---- */

static void *on_session_open(void *cls, void *conn) {
    flect_session_id_t unused;
    flect_receiver_t *r = resolve(cls, &unused);
    session_t *s = calloc(1, sizeof(session_t));
    if (!s) {
        return NULL;  /* the connection falls back to the receiver's context */
    }
    s->kind = CONTEXT_SESSION;
    s->receiver = r;
    s->conn = conn;
    pthread_mutex_lock(&r->sessions_lock);
    s->id = ++r->next_session_id;
    s->next = r->sessions;
    r->sessions = s;
    pthread_mutex_unlock(&r->sessions_lock);
    return s;
}

static void on_session_close(void *cls, void *session_cls) {
    flect_session_id_t unused;
    flect_receiver_t *r = resolve(cls, &unused);
    session_t *s = session_cls;
    pthread_mutex_lock(&r->sessions_lock);
    for (session_t **link = &r->sessions; *link; link = &(*link)->next) {
        if (*link == s) {
            *link = s->next;
            break;
        }
    }
    pthread_mutex_unlock(&r->sessions_lock);
    NOTIFY(r, session_ended, s->id);
    free(s);
}

/* ---- raop callbacks (network threads) ---- */

static void on_log(void *cls, int level, const char *message) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    NOTIFY(r, log, level, message);
}

static void on_conn_init(void *cls) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    int open = atomic_fetch_add(&r->open_connections, 1) + 1;
    NOTIFY(r, connections_changed, open);
}

static void on_conn_destroy(void *cls) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    int open = atomic_fetch_sub(&r->open_connections, 1) - 1;
    if (open < 0) {
        atomic_store(&r->open_connections, 0);
        open = 0;
    }
    NOTIFY(r, connections_changed, open);
}

static void on_conn_reset(void *cls, int reason) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    NOTIFY(r, connection_lost, session, reason);
}

static void on_conn_feedback(void *cls) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    NOTIFY(r, heartbeat, session);
}

static void on_client_request(void *cls, char *device_id, char *model, char *name, bool *admit) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    *admit = true;
    NOTIFY(r, client_request, session, device_id ? device_id : "", model ? model : "",
           name ? name : "", admit);
}

static void on_display_pin(void *cls, char *pin) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    NOTIFY(r, show_code, session, pin);
}

static const char *on_passwd(void *cls, int *len) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    switch (r->access) {
    case FLECT_ACCESS_PASSWORD:
        *len = (int) strlen(r->password);
        return r->password;
    case FLECT_ACCESS_SCREEN_CODE:
        *len = -1; /* the library makes up a code and asks us to show it */
        return NULL;
    default:
        *len = 0;
        return NULL;
    }
}

static int on_video_set_codec(void *cls, video_codec_t codec) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    if (!r->callbacks.video_codec) {
        return codec == VIDEO_CODEC_H264 ? 0 : -1;
    }
    return r->callbacks.video_codec(r->callbacks.context, session, codec == VIDEO_CODEC_H265);
}

static void on_video_process(void *cls, raop_ntp_t *ntp, video_decode_struct *data) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    (void) ntp;
    if (data->data_len <= 0) {
        return;
    }
    NOTIFY(r, video_frame, session, data->data, (size_t) data->data_len, data->nal_count,
           data->is_h265, data->ntp_time_remote);
}

static void on_video_report_size(void *cls, float *width_source, float *height_source,
                                 float *width, float *height) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    NOTIFY(r, video_size, session, *width_source, *height_source, *width, *height);
}

static void on_video_pause(void *cls) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    NOTIFY(r, video_paused, session, true);
}

static void on_video_resume(void *cls) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    NOTIFY(r, video_paused, session, false);
}

static void on_video_reset(void *cls, reset_type_t type) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    if (type == RESET_TYPE_ON_VIDEO_PLAY) {
        return;
    }
    NOTIFY(r, video_stopped, session);
}

static void on_audio_get_format(void *cls, unsigned char *ct, unsigned short *spf,
                                bool *using_screen, bool *is_media, uint64_t *audio_format) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    (void) audio_format;
    NOTIFY(r, audio_format, session, (int) *ct, (int) *spf, *using_screen, *is_media);
}

static void on_audio_process(void *cls, raop_ntp_t *ntp, audio_decode_struct *data) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    (void) ntp;
    if (data->data_len <= 0) {
        return;
    }
    NOTIFY(r, audio_packet, session, data->data, (size_t) data->data_len, (int) data->ct,
           data->ntp_time_remote);
}

static void on_audio_set_volume(void *cls, float volume) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    NOTIFY(r, audio_volume, session, volume);
}

static double on_audio_set_client_volume(void *cls) {
    (void) cls;
    return 0.0; /* start at full volume; the device adjusts from there */
}

static void on_audio_flush(void *cls) {
    flect_session_id_t session;
    flect_receiver_t *r = resolve(cls, &session);
    NOTIFY(r, audio_flush, session);
}

/* HLS ("AirPlay video", e.g. YouTube) is not advertised. These stubs keep the
   library safe if a device asks anyway. */
static void on_video_play(void *cls, const char *location, const float start_position) {
    (void) cls; (void) location; (void) start_position;
}

static void on_video_scrub(void *cls, const float position) {
    (void) cls; (void) position;
}

static void on_video_rate(void *cls, const float rate) {
    (void) cls; (void) rate;
}

static void on_video_stop(void *cls) {
    (void) cls;
}

static void on_video_acquire_playback_info(void *cls, playback_info_t *playback_info) {
    (void) cls;
    playback_info->duration = -1.0; /* "finished": the library then closes the request */
}

static float on_video_playlist_remove(void *cls) {
    (void) cls;
    return 0.0f;
}

/* ---- public API ---- */

flect_receiver_t *flect_receiver_start(const flect_config_t *config,
                                       const flect_callbacks_t *callbacks,
                                       char *error, size_t error_size) {
    unsigned char hw_addr[6];

    if (!config || !callbacks || !config->name || !config->name[0]) {
        set_error(error, error_size, "The receiver needs a name.");
        return NULL;
    }
    if (!parse_device_id(config->device_id, hw_addr)) {
        set_error(error, error_size, "Invalid device ID \"%s\".",
                  config->device_id ? config->device_id : "");
        return NULL;
    }

    flect_receiver_t *r = calloc(1, sizeof(flect_receiver_t));
    if (!r) {
        set_error(error, error_size, "Out of memory.");
        return NULL;
    }
    r->kind = CONTEXT_RECEIVER;
    r->callbacks = *callbacks;
    r->access = config->access;
    r->password = strdup(config->password ? config->password : "");
    atomic_init(&r->open_connections, 0);
    pthread_mutex_init(&r->sessions_lock, NULL);

    int dnssd_error = 0;
    r->dnssd = dnssd_init(config->name, (int) strlen(config->name), (const char *) hw_addr,
                          (int) sizeof(hw_addr), (unsigned char) config->access, &dnssd_error);
    if (!r->dnssd || dnssd_error) {
        set_error(error, error_size, "Could not set up Bonjour (error %d).", dnssd_error);
        goto fail;
    }
    /* Same feature set as uxplay.cpp's start_dnssd, without HLS or legacy pairing. */
    dnssd_set_airplay_features(r->dnssd, 0, 0);   /* AirPlay video (HLS) */
    dnssd_set_airplay_features(r->dnssd, 4, 0);   /* HLS */
    dnssd_set_airplay_features(r->dnssd, 27, 0);  /* legacy pairing (only for remembered PINs) */
    dnssd_set_airplay_features(r->dnssd, 42, config->allow_h265 ? 1 : 0);

    raop_callbacks_t raop_cbs;
    memset(&raop_cbs, 0, sizeof(raop_cbs));
    raop_cbs.cls = r;
    raop_cbs.session_open = on_session_open;
    raop_cbs.session_close = on_session_close;
    raop_cbs.conn_init = on_conn_init;
    raop_cbs.conn_destroy = on_conn_destroy;
    raop_cbs.conn_reset = on_conn_reset;
    raop_cbs.conn_feedback = on_conn_feedback;
    raop_cbs.report_client_request = on_client_request;
    raop_cbs.display_pin = on_display_pin;
    raop_cbs.passwd = on_passwd;
    raop_cbs.video_set_codec = on_video_set_codec;
    raop_cbs.video_process = on_video_process;
    raop_cbs.video_report_size = on_video_report_size;
    raop_cbs.video_pause = on_video_pause;
    raop_cbs.video_resume = on_video_resume;
    raop_cbs.video_reset = on_video_reset;
    raop_cbs.audio_get_format = on_audio_get_format;
    raop_cbs.audio_process = on_audio_process;
    raop_cbs.audio_set_volume = on_audio_set_volume;
    raop_cbs.audio_set_client_volume = on_audio_set_client_volume;
    raop_cbs.audio_flush = on_audio_flush;
    raop_cbs.on_video_play = on_video_play;
    raop_cbs.on_video_scrub = on_video_scrub;
    raop_cbs.on_video_rate = on_video_rate;
    raop_cbs.on_video_stop = on_video_stop;
    raop_cbs.on_video_acquire_playback_info = on_video_acquire_playback_info;
    raop_cbs.on_video_playlist_remove = on_video_playlist_remove;

    r->raop = raop_init(&raop_cbs);
    if (!r->raop) {
        set_error(error, error_size, "Could not start the AirPlay server (network setup failed).");
        goto fail;
    }
    raop_set_log_callback(r->raop, on_log, r);
    raop_set_log_level(r->raop, config->log_level);

    /* nohold = 0: once max_clients devices are connected, others are turned away
       rather than taking over. */
    if (raop_init2(r->raop, 0, config->device_id, config->key_file ? config->key_file : "")) {
        set_error(error, error_size, "Could not create the pairing key.");
        raop_destroy(r->raop);
        r->raop = NULL;
        goto fail;
    }
    raop_set_max_clients(r->raop, config->max_clients > 0 ? config->max_clients : 1);

    if (config->width > 0) raop_set_plist(r->raop, "width", config->width);
    if (config->height > 0) raop_set_plist(r->raop, "height", config->height);
    if (config->max_fps > 0) {
        raop_set_plist(r->raop, "refreshRate", config->max_fps);
        raop_set_plist(r->raop, "maxFPS", config->max_fps);
    }

    /* All ports 0: let the system pick free ones, so Flect can run
       alongside macOS's own AirPlay Receiver, and each device gets its own. */
    unsigned short tcp[2] = { 0, 0 };
    unsigned short udp[3] = { 0, 0, 0 };
    raop_set_tcp_ports(r->raop, tcp);
    raop_set_udp_ports(r->raop, udp);

    unsigned short port = raop_get_port(r->raop);
    if (raop_start_httpd(r->raop, &port) <= 0) {
        set_error(error, error_size, "Could not open a network port for AirPlay.");
        goto fail;
    }
    raop_set_port(r->raop, port);
    r->port = port;
    raop_set_dnssd(r->raop, r->dnssd);

    if (config->advertise) {
        int result = dnssd_register_raop(r->dnssd, port);
        if (!result) {
            result = dnssd_register_airplay(r->dnssd, port);
        }
        if (result) {
            set_error(error, error_size,
                      "Could not announce Flect on the network (Bonjour error %d).", result);
            goto fail;
        }
    }
    return r;

fail:
    flect_receiver_stop(r);
    return NULL;
}

void flect_receiver_stop(flect_receiver_t *r) {
    if (!r) {
        return;
    }
    if (r->dnssd) {
        /* Safe even if registration never happened or only half succeeded. */
        dnssd_unregister_raop(r->dnssd);
        dnssd_unregister_airplay(r->dnssd);
    }
    if (r->raop) {
        /* Closes every connection, ending each session. */
        raop_destroy(r->raop);
        r->raop = NULL;
    }
    if (r->dnssd) {
        dnssd_destroy(r->dnssd);
        r->dnssd = NULL;
    }
    while (r->sessions) {
        session_t *next = r->sessions->next;
        free(r->sessions);
        r->sessions = next;
    }
    pthread_mutex_destroy(&r->sessions_lock);
    free(r->password);
    free(r);
}

void flect_receiver_reset_connections(flect_receiver_t *r) {
    if (!r || !r->raop) {
        return;
    }
    /* Same sequence uxplay.cpp uses after a lost connection. */
    raop_stop_httpd(r->raop);
    raop_remove_known_connections(r->raop);
    unsigned short port = r->port;
    raop_start_httpd(r->raop, &port);
    raop_set_port(r->raop, port);
}

void flect_receiver_disconnect(flect_receiver_t *r, flect_session_id_t session) {
    if (!r || !r->raop || session == 0) {
        return;
    }
    /* Holding the lock keeps the session, and so its connection, alive:
       the library ends a session before freeing the connection. */
    pthread_mutex_lock(&r->sessions_lock);
    for (session_t *s = r->sessions; s; s = s->next) {
        if (s->id == session) {
            raop_remove_connection(r->raop, s->conn);
            break;
        }
    }
    pthread_mutex_unlock(&r->sessions_lock);
}

unsigned short flect_receiver_port(const flect_receiver_t *r) {
    return r ? r->port : 0;
}
