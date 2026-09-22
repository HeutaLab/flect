/*
 * Flect — AirPlay receiver for Mac
 * Copyright (C) 2026 Flect contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * A small, stable C interface over UxPlay's AirPlay protocol library.
 * Everything UxPlay-specific stays behind this header, so the vendored
 * library can be updated without touching the Swift code.
 */

#ifndef FLECT_RECEIVER_H
#define FLECT_RECEIVER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct flect_receiver flect_receiver_t;

/* One connected device, for as long as it stays connected. Never reused.
   0 means "not tied to a device". */
typedef uint32_t flect_session_id_t;

/* Who may mirror (UxPlay's pin_pw modes). */
typedef enum {
    FLECT_ACCESS_OPEN = 0,        /* anyone on the network */
    FLECT_ACCESS_PASSWORD = 2,    /* a fixed password */
    FLECT_ACCESS_SCREEN_CODE = 3  /* a fresh 4-digit code, shown on screen, for every connection */
} flect_access_t;

/* AirPlay audio compression types ("ct"). */
typedef enum {
    FLECT_AUDIO_PCM = 1,
    FLECT_AUDIO_ALAC = 2,
    FLECT_AUDIO_AAC_LC = 4,
    FLECT_AUDIO_AAC_ELD = 8
} flect_audio_type_t;

/* Log levels, syslog style (same values as UxPlay's logger). */
enum {
    FLECT_LOG_ERROR = 3,
    FLECT_LOG_WARNING = 4,
    FLECT_LOG_NOTICE = 5,
    FLECT_LOG_INFO = 6,
    FLECT_LOG_DEBUG = 7
};

/*
 * Callbacks arrive on the receiver's own network threads, never the main
 * thread; with several devices connected they arrive concurrently.
 * Buffers are only valid for the duration of the call. Any callback may
 * be NULL.
 */
typedef struct {
    void *context;

    void (*log)(void *context, int level, const char *message);
    /* Network connections open, across all devices. */
    void (*connections_changed)(void *context, int open_connections);

    /* A device asks to start mirroring or playing. Leave *admit true to accept it. */
    void (*client_request)(void *context, flect_session_id_t session, const char *device_id,
                           const char *model, const char *name, bool *admit);
    /* The device's connection closed. No more callbacks for this session. */
    void (*session_ended)(void *context, flect_session_id_t session);
    /* The device's connection dropped unexpectedly (Wi-Fi, sleep...). */
    void (*connection_lost)(void *context, flect_session_id_t session, int reason);
    /* The device checks in roughly every two seconds. */
    void (*heartbeat)(void *context, flect_session_id_t session);
    /* The device is asking its user to type this code. */
    void (*show_code)(void *context, flect_session_id_t session, const char *code);

    /* Return 0 to accept the codec, -1 to refuse it. */
    int  (*video_codec)(void *context, flect_session_id_t session, bool is_h265);
    /* Annex B NAL units (00 00 00 01 start codes). Parameter sets are
       prepended to the first frame after they change. */
    void (*video_frame)(void *context, flect_session_id_t session, const uint8_t *data,
                        size_t length, int nal_count, bool is_h265, uint64_t remote_time_ns);
    void (*video_size)(void *context, flect_session_id_t session, float source_width,
                       float source_height, float width, float height);
    void (*video_paused)(void *context, flect_session_id_t session, bool paused);
    void (*video_stopped)(void *context, flect_session_id_t session);

    void (*audio_format)(void *context, flect_session_id_t session, int audio_type,
                         int samples_per_frame, bool using_screen, bool is_media);
    void (*audio_packet)(void *context, flect_session_id_t session, const uint8_t *data,
                         size_t length, int audio_type, uint64_t remote_time_ns);
    /* AirPlay volume in dB: -30 (quietest) to 0 (full); -144 means mute. */
    void (*audio_volume)(void *context, flect_session_id_t session, float volume_db);
    void (*audio_flush)(void *context, flect_session_id_t session);
} flect_callbacks_t;

typedef struct {
    const char *name;           /* shown in the iPad's Screen Mirroring list */
    const char *device_id;      /* stable "xx:xx:xx:xx:xx:xx" identity */
    const char *key_file;       /* PEM file for the persistent pairing key ("" = derive from device_id) */
    flect_access_t access;
    const char *password;       /* for FLECT_ACCESS_PASSWORD */
    int max_clients;            /* devices connected at once (default 1) */
    bool allow_h265;
    int width;                  /* largest picture a device should send */
    int height;
    int max_fps;
    bool advertise;             /* false: skip Bonjour (used by tests) */
    int log_level;
} flect_config_t;

/* Starts the AirPlay server and advertises it. Returns NULL on failure,
   with a readable reason in error (if given). */
flect_receiver_t *flect_receiver_start(const flect_config_t *config,
                                       const flect_callbacks_t *callbacks,
                                       char *error, size_t error_size);

/* Stops advertising, closes every connection and frees the receiver. */
void flect_receiver_stop(flect_receiver_t *receiver);

/* Drops every connection and starts listening again on the same port. */
void flect_receiver_reset_connections(flect_receiver_t *receiver);

/* Drops one device's connection, within about a second. The device sees
   mirroring stop; the others carry on. */
void flect_receiver_disconnect(flect_receiver_t *receiver, flect_session_id_t session);

unsigned short flect_receiver_port(const flect_receiver_t *receiver);

#ifdef __cplusplus
}
#endif

#endif /* FLECT_RECEIVER_H */
