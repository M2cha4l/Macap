// Privileged single-purpose UVC Bulk reader helper for Macap.
//
// Security properties:
//   1. Links ONLY SIP-protected macOS system frameworks (IOKit, IOSurface, CoreFoundation, libSystem).
//      Zero Homebrew or @rpath dylibs, preventing privilege escalation via user-writable libraries.
//   2. Hardcodes USB VID=0x0bda, PID=0x0911, Video Interface=1 (Bulk IN 0x82), Audio Interface=5 (Isoch IN 0x86).
//   3. Accepts ONLY whitelisted mode/action flags (--mode 4k60|4k30|2k60|1080p60, --recover, --selftest).
//      Rejects all file paths, shell strings, or unknown options.
//   4. Shares 8 NV12 IOSurface slots via private Mach port message (no deprecated global IOSurfaces).
//   5. Watches parent/client process exit (EVFILT_PROC NOTE_EXIT + stdin EOF) and signals (SIGINT/SIGTERM/SIGHUP)
//      to abort pipes, close interfaces, and release whole-device capture back to macOS on exit.
//
// Build:
//   clang -O2 -Wall -Wextra -Werror tools/uvc_bulk_helper.c \
//     -framework IOKit -framework IOSurface -framework CoreFoundation \
//     -o Macap.app/Contents/MacOS/macap-uvc-helper

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOSurface/IOSurface.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <poll.h>
#include <pthread.h>
#include <servers/bootstrap.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <unistd.h>

enum {
    TARGET_VID          = 0x0bda,
    TARGET_PID          = 0x0911,
    STREAM_INTERFACE    = 1,
    BULK_IN_EP          = 0x82,
    AUDIO_INTERFACE     = 5,
    AUDIO_IN_EP         = 0x86,
    AUDIO_ISOC_XFERS    = 4,
    AUDIO_ISOC_FRAMES   = 10,
    AUDIO_ISOC_MPS      = 208,
    RING_SLOTS          = 8,
    NUM_URBS            = 32,
    URB_BYTES           = 262144,
    DEFAULT_SLICE_BYTES = 16384,
    PIXEL_FMT_NV12      = 0x34323076u, // '420v' kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    HELLO_MAGIC         = 0x55564348u, // "UVCH"
    HELLO_FLAG_AUDIO    = 0x00010000u,
    READY_MAGIC         = 0x55565244u, // "UVRD"
    READY_FLAG_AUDIO    = 0x00000100u,
    READY_FLAG_CAPTURED = 0x00000200u,
    FRAME_MAGIC         = 0x55564652u, // "UVFR"
    AUDIO_MAGIC         = 0x55564155u, // "UVAU"
    MACH_PORT_MSG_ID    = 0x55565054u  // "UVPT"
};

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t version;
    uint32_t client_pid;
    uint32_t ring_slots;
    uint64_t nonce;
} client_hello_t;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t width;
    uint32_t height;
    uint32_t pixel_format;
    uint32_t ring_slots;
    uint32_t usb_speed;
} server_ready_t;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t slot;
    uint64_t seq;
    uint64_t pts_mach;
    uint64_t arrival_mach;
} frame_packet_t;

typedef struct {
    mach_msg_header_t hdr;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t ports[RING_SLOTS];
} mach_ports_send_msg_t;

typedef struct {
    const char *name;
    uint32_t width;
    uint32_t height;
    uint8_t fmt_idx;
    uint8_t frm_idx;
    uint32_t interval_100ns;
} stream_mode_t;

static const stream_mode_t kModes[] = {
    { "4k60",    3840, 2160, 3, 8, 166666 },
    { "4k30",    3840, 2160, 3, 8, 333333 },
    { "2k60",    2560, 1440, 3, 6, 166666 },
    { "1080p60", 1920, 1080, 3, 4, 166666 },
};

static volatile sig_atomic_t g_stop_signal = 0;
static atomic_int g_running = 1;
static CFRunLoopRef g_main_rl = NULL;

static void on_signal(int sig) {
    (void)sig;
    g_stop_signal = 1;
    atomic_store(&g_running, 0);
}

static int write_full(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        if (g_stop_signal || !atomic_load(&g_running)) return -1;
        // Poll with 250 ms slices (up to 2 s) so a SIGSTOPped/stalled client cannot block SIGTERM/run_recover().
        int waited = 0;
        while (waited < 8) {
            struct pollfd pfd = { .fd = fd, .events = POLLOUT, .revents = 0 };
            int pr = poll(&pfd, 1, 250);
            if (g_stop_signal || !atomic_load(&g_running)) return -1;
            if (pr > 0) {
                if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) return -1;
                if (pfd.revents & POLLOUT) break;
            } else if (pr < 0 && errno != EINTR) {
                return -1;
            }
            waited++;
        }
        if (waited >= 8) return -1;

        ssize_t n = write(fd, p + off, len - off);
        if (n < 0) {
            if (errno == EINTR) {
                if (g_stop_signal || !atomic_load(&g_running)) return -1;
                continue;
            }
            return -1;
        }
        if (n == 0) return -1;
        off += (size_t)n;
    }
    return 0;
}

static int read_full(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = read(fd, p + off, len - off);
        if (n < 0) {
            if (errno == EINTR) {
                if (g_stop_signal || !atomic_load(&g_running)) return -1;
                continue;
            }
            return -1;
        }
        if (n == 0) return -1;
        off += (size_t)n;
    }
    return 0;
}

// Plane writer abstracted so offline --selftest can test padded strides without IOSurface if needed,
// and production writes directly into locked IOSurface plane memory.
typedef struct {
    uint8_t *y_base;
    uint8_t *uv_base;
    size_t width;
    size_t height;
    size_t y_bpr;
    size_t uv_bpr;
} nv12_dest_t;

static void write_nv12_bytes(const nv12_dest_t *dst, size_t frame_off, const uint8_t *src, size_t len) {
    if (!dst || !dst->y_base || !dst->uv_base || len == 0) return;
    const size_t y_logical = dst->width * dst->height;
    const size_t uv_logical = dst->width * (dst->height / 2);
    const size_t total_logical = y_logical + uv_logical;
    if (frame_off >= total_logical) return;
    if (frame_off + len > total_logical) {
        len = total_logical - frame_off;
    }

    // Y plane segment
    if (frame_off < y_logical) {
        size_t y_take = (frame_off + len <= y_logical) ? len : (y_logical - frame_off);
        if (dst->y_bpr == dst->width) {
            memcpy(dst->y_base + frame_off, src, y_take);
        } else {
            size_t rem = y_take, cur = frame_off;
            const uint8_t *sp = src;
            while (rem > 0) {
                size_t row = cur / dst->width;
                size_t col = cur % dst->width;
                size_t chunk = dst->width - col;
                if (chunk > rem) chunk = rem;
                memcpy(dst->y_base + row * dst->y_bpr + col, sp, chunk);
                cur += chunk;
                sp += chunk;
                rem -= chunk;
            }
        }
        src += y_take;
        frame_off += y_take;
        len -= y_take;
    }

    // UV plane segment
    if (len > 0) {
        size_t uv_off = frame_off - y_logical;
        if (dst->uv_bpr == dst->width) {
            memcpy(dst->uv_base + uv_off, src, len);
        } else {
            size_t rem = len, cur = uv_off;
            const uint8_t *sp = src;
            while (rem > 0) {
                size_t row = cur / dst->width;
                size_t col = cur % dst->width;
                size_t chunk = dst->width - col;
                if (chunk > rem) chunk = rem;
                memcpy(dst->uv_base + row * dst->uv_bpr + col, sp, chunk);
                cur += chunk;
                sp += chunk;
                rem -= chunk;
            }
        }
    }
}

typedef struct helper_ctx helper_ctx_t;

typedef void (*frame_emit_fn)(helper_ctx_t *ctx, int slot, uint64_t pts_mach, uint64_t arrival_mach);

struct helper_ctx {
    uint32_t width;
    uint32_t height;
    size_t expected_frame_bytes;
    uint32_t max_payload_bytes;
    uint32_t clock_hz;
    uint32_t usb_speed; // 5 = 10Gbps, 4 = 5Gbps
    mach_timebase_info_data_t tb;
    uint64_t last_deliv_mach;
    uint64_t no_slot_drops;
    atomic_int urbs_in_flight;
    atomic_int audio_in_flight;

    IOSurfaceRef surfaces[RING_SLOTS];
    atomic_int pending_ack[RING_SLOTS];
    bool mock_in_use[RING_SLOTS]; // used only in --selftest
    bool is_selftest;
    int next_search_slot;

    int cur_slot;
    bool cur_locked;
    nv12_dest_t cur_dest;

    int last_fid;
    int slice_in_frame;
    size_t bytes_in_frame;
    bool frame_corrupt;
    bool has_pts_scr;
    uint32_t cur_pts_27m;
    uint32_t last_stc_27m;
    size_t last_urb_bytes;
    uint64_t seq;
    uint64_t prev_pts_mach;

    int out_fd;
    uint32_t client_pid;
    frame_emit_fn on_frame;
};

static bool slot_busy(helper_ctx_t *ctx, int s) {
    if (atomic_load(&ctx->pending_ack[s]) != 0) return true;
    if (ctx->is_selftest) return ctx->mock_in_use[s];
    return ctx->surfaces[s] ? (IOSurfaceIsInUse(ctx->surfaces[s]) != 0) : true;
}

static int acquire_free_slot(helper_ctx_t *ctx) {
    for (int i = 0; i < RING_SLOTS; i++) {
        int s = (ctx->next_search_slot + i) % RING_SLOTS;
        if (!slot_busy(ctx, s)) {
            ctx->next_search_slot = (s + 1) % RING_SLOTS;
            if (!ctx->is_selftest) {
                if (IOSurfaceLock(ctx->surfaces[s], 0, NULL) != kIOReturnSuccess) {
                    continue;
                }
                ctx->cur_dest.y_base  = (uint8_t *)IOSurfaceGetBaseAddressOfPlane(ctx->surfaces[s], 0);
                ctx->cur_dest.uv_base = (uint8_t *)IOSurfaceGetBaseAddressOfPlane(ctx->surfaces[s], 1);
                ctx->cur_dest.width   = ctx->width;
                ctx->cur_dest.height  = ctx->height;
                ctx->cur_dest.y_bpr   = IOSurfaceGetBytesPerRowOfPlane(ctx->surfaces[s], 0);
                ctx->cur_dest.uv_bpr  = IOSurfaceGetBytesPerRowOfPlane(ctx->surfaces[s], 1);
                ctx->cur_locked = true;
            }
            ctx->cur_slot = s;
            return s;
        }
    }
    ctx->cur_slot = -1;
    ctx->cur_locked = false;
    ctx->no_slot_drops++;
    if (ctx->no_slot_drops == 1 || (ctx->no_slot_drops % 60) == 0) {
        fprintf(stderr, "uvc_bulk_helper: ring full, dropped %llu frames\n",
                (unsigned long long)ctx->no_slot_drops);
    }
    return -1;
}

static void release_active_slot_lock(helper_ctx_t *ctx) {
    if (ctx->cur_locked && ctx->cur_slot >= 0 && !ctx->is_selftest && ctx->surfaces[ctx->cur_slot]) {
        IOSurfaceUnlock(ctx->surfaces[ctx->cur_slot], 0, NULL);
    }
    ctx->cur_locked = false;
}

static uint64_t compute_pts_mach(helper_ctx_t *ctx, uint64_t eof_mach) {
    uint64_t deliv_mach = ctx->last_deliv_mach;
    uint32_t clk = ctx->clock_hz ? ctx->clock_hz : 27000000u;
    if (ctx->has_pts_scr && ctx->tb.numer > 0) {
        uint32_t delta_ticks = ctx->last_stc_27m - ctx->cur_pts_27m; // modular 32-bit wrap-safe!
        uint64_t max_ticks = ((uint64_t)clk * 80ULL) / 1000ULL;      // 80 ms ceiling
        if (delta_ticks <= max_ticks) {
            uint64_t card_ns = ((uint64_t)delta_ticks * 1000000000ULL) / (uint64_t)clk;
            uint64_t wire_rate_mb_s = (ctx->usb_speed >= 5) ? 740ULL : 380ULL;
            uint64_t wire_ns = ((uint64_t)ctx->last_urb_bytes * 1000ULL) / wire_rate_mb_s;
            uint64_t total_ns = card_ns + wire_ns;
            deliv_mach = (total_ns * (uint64_t)ctx->tb.denom) / (uint64_t)ctx->tb.numer;
            ctx->last_deliv_mach = deliv_mach;
        }
    }
    uint64_t pts_mach = (eof_mach > deliv_mach) ? (eof_mach - deliv_mach) : eof_mach;
    if (pts_mach <= ctx->prev_pts_mach) {
        pts_mach = ctx->prev_pts_mach + 1;
    }
    ctx->prev_pts_mach = pts_mach;
    return pts_mach;
}

static void complete_current_frame(helper_ctx_t *ctx) {
    bool valid = (!ctx->frame_corrupt &&
                  ctx->cur_slot >= 0 &&
                  ctx->bytes_in_frame == ctx->expected_frame_bytes);

    release_active_slot_lock(ctx);

    if (valid) {
        int slot = ctx->cur_slot;
        uint64_t eof_mach = mach_absolute_time();
        uint64_t pts_mach = compute_pts_mach(ctx, eof_mach);
        atomic_store(&ctx->pending_ack[slot], 1);
        ctx->seq++;
        if (ctx->on_frame) {
            ctx->on_frame(ctx, slot, pts_mach, eof_mach);
        }
    }

    ctx->cur_slot = -1;
    ctx->bytes_in_frame = 0;
    ctx->slice_in_frame = 0;
    ctx->frame_corrupt = false;
    ctx->has_pts_scr = false;
}

static void parse_uvc_urb(helper_ctx_t *ctx, const uint8_t *buf, size_t len) {
    if (len == 0) return;
    ctx->last_urb_bytes = len;
    const size_t step = ctx->max_payload_bytes ? ctx->max_payload_bytes : DEFAULT_SLICE_BYTES;
    size_t off = 0;

    while (off < len) {
        size_t rem = len - off;
        size_t clen = (rem < step) ? rem : step;
        const uint8_t *p = buf + off;

        if (clen >= 2) {
            uint8_t hlen = p[0];
            uint8_t hinfo = p[1];
            // Valid UVC 1.1/1.5 payload header: length 2..16, EOH bit (0x80) set
            if (hlen >= 2 && hlen <= 16 && hlen <= clen && (hinfo & 0x80)) {
                int fid = hinfo & 0x01;
                int eof = (hinfo >> 1) & 0x01;
                int has_pts = (hinfo >> 2) & 0x01;
                int has_scr = (hinfo >> 3) & 0x01;
                int err_bit = (hinfo >> 6) & 0x01;

                // Frame boundary via FID toggle if prior EOF packet was missed
                if (ctx->last_fid != -1 && fid != ctx->last_fid && ctx->slice_in_frame > 0) {
                    complete_current_frame(ctx);
                }
                ctx->last_fid = fid;

                if (ctx->slice_in_frame == 0) {
                    acquire_free_slot(ctx);
                    if (has_pts && has_scr && hlen >= 12) {
                        memcpy(&ctx->cur_pts_27m, p + 2, 4);
                        ctx->has_pts_scr = true;
                    }
                }
                if (has_pts && has_scr && hlen >= 12) {
                    memcpy(&ctx->last_stc_27m, p + 6, 4);
                }
                if (err_bit) {
                    ctx->frame_corrupt = true;
                }

                size_t pay = clen - hlen;
                if (pay > 0) {
                    if (ctx->bytes_in_frame + pay <= ctx->expected_frame_bytes) {
                        if (ctx->cur_slot >= 0 && !ctx->frame_corrupt) {
                            write_nv12_bytes(&ctx->cur_dest, ctx->bytes_in_frame, p + hlen, pay);
                        }
                    } else {
                        ctx->frame_corrupt = true;
                    }
                    ctx->bytes_in_frame += pay;
                }
                ctx->slice_in_frame++;

                if (eof) {
                    complete_current_frame(ctx);
                }
            } else {
                // Unexpected non-header chunk in stream: mark current frame corrupt
                ctx->frame_corrupt = true;
            }
        }
        off += clen;
    }
}

static void emit_frame_to_pipe(helper_ctx_t *ctx, int slot, uint64_t pts_mach, uint64_t arrival_mach) {
    frame_packet_t pkt;
    pkt.magic        = FRAME_MAGIC;
    pkt.slot         = (uint32_t)slot;
    pkt.seq          = ctx->seq;
    pkt.pts_mach     = pts_mach;
    pkt.arrival_mach = arrival_mach;
    if (write_full(ctx->out_fd, &pkt, sizeof(pkt)) != 0) {
        atomic_store(&g_running, 0);
        if (g_main_rl) CFRunLoopStop(g_main_rl);
    }
}

// ---------------- IOSurface Ring Allocation & Private Mach Port Transfer ----------------

static void dict_set_i32(CFMutableDictionaryRef d, CFStringRef k, int32_t v) {
    CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &v);
    CFDictionarySetValue(d, k, n);
    CFRelease(n);
}

static void dict_set_i64(CFMutableDictionaryRef d, CFStringRef k, int64_t v) {
    CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &v);
    CFDictionarySetValue(d, k, n);
    CFRelease(n);
}

static IOSurfaceRef create_nv12_surface(uint32_t width, uint32_t height) {
    size_t align = IOSurfaceGetPropertyAlignment(kIOSurfacePlaneBytesPerRow);
    if (align == 0) align = 16;
    size_t y_bpr  = ((size_t)width + align - 1) & ~(align - 1);
    size_t uv_bpr = y_bpr;
    size_t y_size  = y_bpr * (size_t)height;
    size_t uv_size = uv_bpr * ((size_t)height / 2);
    size_t plane_align = IOSurfaceGetPropertyAlignment(kIOSurfacePlaneOffset);
    if (plane_align > 1) {
        y_size = (y_size + plane_align - 1) & ~(plane_align - 1);
    }
    size_t total = y_size + uv_size;

    CFMutableDictionaryRef p0 = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    dict_set_i32(p0, kIOSurfacePlaneWidth, (int32_t)width);
    dict_set_i32(p0, kIOSurfacePlaneHeight, (int32_t)height);
    dict_set_i32(p0, kIOSurfacePlaneBytesPerElement, 1);
    dict_set_i32(p0, kIOSurfacePlaneBytesPerRow, (int32_t)y_bpr);
    dict_set_i64(p0, kIOSurfacePlaneSize, (int64_t)y_size);
    dict_set_i64(p0, kIOSurfacePlaneOffset, 0);

    CFMutableDictionaryRef p1 = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    dict_set_i32(p1, kIOSurfacePlaneWidth, (int32_t)(width / 2));
    dict_set_i32(p1, kIOSurfacePlaneHeight, (int32_t)(height / 2));
    dict_set_i32(p1, kIOSurfacePlaneBytesPerElement, 2);
    dict_set_i32(p1, kIOSurfacePlaneBytesPerRow, (int32_t)uv_bpr);
    dict_set_i64(p1, kIOSurfacePlaneSize, (int64_t)uv_size);
    dict_set_i64(p1, kIOSurfacePlaneOffset, (int64_t)y_size);

    const void *planes_raw[2] = { p0, p1 };
    CFArrayRef planes = CFArrayCreate(kCFAllocatorDefault, planes_raw, 2, &kCFTypeArrayCallBacks);

    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    dict_set_i32(props, kIOSurfaceWidth, (int32_t)width);
    dict_set_i32(props, kIOSurfaceHeight, (int32_t)height);
    dict_set_i32(props, kIOSurfacePixelFormat, (int32_t)PIXEL_FMT_NV12);
    dict_set_i64(props, kIOSurfaceAllocSize, (int64_t)total);
    CFDictionarySetValue(props, kIOSurfacePlaneInfo, planes);

    IOSurfaceRef surf = IOSurfaceCreate(props);
    CFRelease(p0);
    CFRelease(p1);
    CFRelease(planes);
    CFRelease(props);
    return surf;
}

static int send_ring_ports_to_client(helper_ctx_t *ctx, uint32_t client_pid, uint64_t nonce) {
    char svc_name[128];
    snprintf(svc_name, sizeof(svc_name), "local.macap.uvc.%u.%016llx",
             client_pid, (unsigned long long)nonce);

    mach_port_t bport = MACH_PORT_NULL;
    if (task_get_bootstrap_port(mach_task_self(), &bport) != KERN_SUCCESS) return -1;

    mach_port_t dst_port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bport, svc_name, &dst_port);
    if (kr != KERN_SUCCESS || dst_port == MACH_PORT_NULL) {
        fprintf(stderr, "uvc_bulk_helper: bootstrap_look_up(%s) failed: 0x%x\n", svc_name, kr);
        return -2;
    }

    mach_ports_send_msg_t msg;
    memset(&msg, 0, sizeof(msg));
    msg.hdr.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND, 0);
    msg.hdr.msgh_size = sizeof(msg);
    msg.hdr.msgh_remote_port = dst_port;
    msg.hdr.msgh_id = MACH_PORT_MSG_ID;
    msg.body.msgh_descriptor_count = RING_SLOTS;

    for (int i = 0; i < RING_SLOTS; i++) {
        mach_port_t mp = IOSurfaceCreateMachPort(ctx->surfaces[i]);
        if (mp == MACH_PORT_NULL) {
            for (int j = 0; j < i; j++) {
                mach_port_deallocate(mach_task_self(), msg.ports[j].name);
            }
            mach_port_deallocate(mach_task_self(), dst_port);
            return -3;
        }
        msg.ports[i].name = mp;
        msg.ports[i].disposition = MACH_MSG_TYPE_MOVE_SEND; // transfers send right cleanly so useCount returns to 0
        msg.ports[i].type = MACH_MSG_PORT_DESCRIPTOR;
    }

    kr = mach_msg(&msg.hdr, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(msg), 0,
                  MACH_PORT_NULL, 2000, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) {
        mach_msg_destroy(&msg.hdr);
        fprintf(stderr, "uvc_bulk_helper: mach_msg send failed: 0x%x\n", kr);
        return -4;
    }
    return 0;
}

// ---------------- Parent Exit + Stdin Slot-Ack Watcher Thread ----------------

static void *client_watch_thread(void *arg) {
    helper_ctx_t *ctx = (helper_ctx_t *)arg;
    int kq = kqueue();
    if (kq < 0) {
        atomic_store(&g_running, 0);
        if (g_main_rl) CFRunLoopStop(g_main_rl);
        return NULL;
    }

    struct kevent kev[2];
    int nreg = 0;
    EV_SET(&kev[nreg++], STDIN_FILENO, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
    if (ctx->client_pid > 1) {
        EV_SET(&kev[nreg++], (uintptr_t)ctx->client_pid, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    }
    kevent(kq, kev, nreg, NULL, 0, NULL);

    while (atomic_load(&g_running)) {
        struct kevent out_ev;
        struct timespec ts = { 0, 250000000 }; // 250 ms
        int nev = kevent(kq, NULL, 0, &out_ev, 1, &ts);
        if (nev < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (nev == 0) continue;

        if (out_ev.filter == EVFILT_PROC) {
            break; // client exited!
        }
        if (out_ev.filter == EVFILT_READ) {
            uint8_t acks[64];
            ssize_t nr = read(STDIN_FILENO, acks, sizeof(acks));
            if (nr <= 0) {
                if (nr < 0 && errno == EINTR) continue;
                break; // stdin EOF -> client closed pipe or died!
            }
            for (ssize_t i = 0; i < nr; i++) {
                uint8_t s = acks[i];
                if (s == 0xFF) {
                    // Explicit graceful stop command
                    atomic_store(&g_running, 0);
                    break;
                }
                if (s < RING_SLOTS) {
                    atomic_store(&ctx->pending_ack[s], 0);
                }
            }
            if ((out_ev.flags & EV_EOF) != 0) {
                break;
            }
        }
    }

    close(kq);
    atomic_store(&g_running, 0);
    if (g_main_rl) CFRunLoopStop(g_main_rl);
    return NULL;
}

// ---------------- IOKit USB Device Lookup, Recovery, and Async Bulk Streaming ----------------

static IOUSBDeviceInterface187 **open_target_usb_device(void) {
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matching) return NULL;
    int32_t vid = TARGET_VID, pid = TARGET_PID;
    dict_set_i32(matching, CFSTR(kUSBVendorID), vid);
    dict_set_i32(matching, CFSTR(kUSBProductID), pid);

    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != KERN_SUCCESS) {
        return NULL;
    }
    io_service_t service = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!service) return NULL;

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || !plug) return NULL;

    IOUSBDeviceInterface187 **dev = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID187), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (hr != S_OK || !dev) return NULL;
    return dev;
}

static int run_recover(void) {
    IOUSBDeviceInterface187 **dev = open_target_usb_device();
    if (!dev) {
        fprintf(stderr, "uvc_bulk_helper: target USB device %04x:%04x not found\n", TARGET_VID, TARGET_PID);
        return 2;
    }
    IOReturn rc = (*dev)->USBDeviceReEnumerate(dev, kUSBReEnumerateReleaseDeviceMask);
    (*dev)->Release(dev);
    if (rc != kIOReturnSuccess) {
        fprintf(stderr, "uvc_bulk_helper: ReleaseDeviceMask failed: 0x%08x\n", (unsigned)rc);
        return 3;
    }
    return 0;
}

static IOUSBInterfaceInterface190 **find_and_open_interface_num(IOUSBDeviceInterface187 **dev, int target_if_num,
                                                                bool allow_seize, IOReturn *last_err) {
    IOUSBFindInterfaceRequest req;
    req.bInterfaceClass    = kIOUSBFindInterfaceDontCare;
    req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    req.bAlternateSetting  = kIOUSBFindInterfaceDontCare;

    io_iterator_t iter = 0;
    if ((*dev)->CreateInterfaceIterator(dev, &req, &iter) != kIOReturnSuccess) {
        return NULL;
    }

    io_service_t target_svc = 0;
    io_service_t svc = 0;
    while ((svc = IOIteratorNext(iter)) != 0) {
        CFNumberRef numRef = IORegistryEntryCreateCFProperty(svc, CFSTR("bInterfaceNumber"), kCFAllocatorDefault, 0);
        int ifnum = -1;
        if (numRef) {
            CFNumberGetValue(numRef, kCFNumberIntType, &ifnum);
            CFRelease(numRef);
        }
        if (ifnum == target_if_num) {
            target_svc = svc;
            break;
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(iter);
    if (!target_svc) return NULL;

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        target_svc, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(target_svc);
    if (kr != KERN_SUCCESS || !plug) return NULL;

    IOUSBInterfaceInterface190 **intf = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID190), (LPVOID *)&intf);
    (*plug)->Release(plug);
    if (hr != S_OK || !intf) return NULL;

    IOReturn orc = (*intf)->USBInterfaceOpen(intf);
    if (orc != kIOReturnSuccess && allow_seize) {
        orc = (*intf)->USBInterfaceOpenSeize(intf);
    }
    if (last_err) *last_err = orc;
    if (orc != kIOReturnSuccess) {
        (*intf)->Release(intf);
        return NULL;
    }
    return intf;
}

static IOUSBInterfaceInterface190 **claim_stream_interfaces(bool want_audio, bool *out_used_device_capture,
                                                            IOUSBInterfaceInterface190 ***out_audio_intf,
                                                            uint32_t *out_usb_speed) {
    *out_used_device_capture = false;
    *out_audio_intf = NULL;
    *out_usb_speed = 5;

    IOUSBDeviceInterface187 **dev = open_target_usb_device();
    if (!dev) {
        fprintf(stderr, "uvc_bulk_helper: capture card %04x:%04x not connected\n", TARGET_VID, TARGET_PID);
        return NULL;
    }
    UInt8 dev_speed = 0;
    (*dev)->GetDeviceSpeed(dev, &dev_speed);
    *out_usb_speed = (dev_speed >= 4) ? 5 : 4;

    // Step 1: Try per-interface open / seize on Interface 1 first (no whole-device capture needed if idle).
    IOReturn last_err = kIOReturnError;
    for (int i = 0; i < 3 && !g_stop_signal; i++) {
        IOUSBInterfaceInterface190 **intf = find_and_open_interface_num(dev, STREAM_INTERFACE, i >= 1, &last_err);
        if (intf) {
            (*dev)->Release(dev);
            return intf;
        }
        if (last_err != kIOReturnExclusiveAccess) break;
        usleep(50000);
    }

    // Step 2: macOS DriverKit uvcassistantextension holds Interface 1 (0xe00002c5); detach via
    // kUSBReEnumerateCaptureDeviceMask (root) and concurrently open Interface 5 (EP 0x86 48kHz HDMI audio)
    // so audio is forwarded cleanly without going silent, releasing the device back to macOS on exit.
    if (last_err != kIOReturnExclusiveAccess || geteuid() != 0) {
        fprintf(stderr, "uvc_bulk_helper: USBInterfaceOpen(1) failed (0x%08x%s)\n",
                (unsigned)last_err, geteuid() != 0 ? "; root required" : "");
        (*dev)->Release(dev);
        return NULL;
    }

    IOReturn cap_rc = (*dev)->USBDeviceReEnumerate(dev, kUSBReEnumerateCaptureDeviceMask);
    (*dev)->Release(dev);
    if (cap_rc != kIOReturnSuccess) {
        fprintf(stderr, "uvc_bulk_helper: CaptureDeviceMask failed: 0x%08x\n", (unsigned)cap_rc);
        return NULL;
    }
    *out_used_device_capture = true;

    for (int wait_i = 0; wait_i < 30 && !g_stop_signal; wait_i++) {
        usleep(100000);
        IOUSBDeviceInterface187 **rdev = open_target_usb_device();
        if (!rdev) continue;
        UInt8 rspeed = 0;
        (*rdev)->GetDeviceSpeed(rdev, &rspeed);
        *out_usb_speed = (rspeed >= 4) ? 5 : 4;
        IOUSBInterfaceInterface190 **vintf = find_and_open_interface_num(rdev, STREAM_INTERFACE, true, &last_err);
        if (vintf) {
            if (want_audio) {
                IOReturn aerr = kIOReturnSuccess;
                for (int atry = 0; atry < 10; atry++) {
                    *out_audio_intf = find_and_open_interface_num(rdev, AUDIO_INTERFACE, true, &aerr);
                    if (*out_audio_intf) break;
                    usleep(50000);
                }
            }
            (*rdev)->Release(rdev);
            return vintf;
        }
        (*rdev)->Release(rdev);
    }

    fprintf(stderr, "uvc_bulk_helper: Interface 1 unavailable after CaptureDeviceMask (0x%08x)\n", (unsigned)last_err);
    run_recover();
    return NULL;
}

static int uvc_ctrl_transfer(IOUSBInterfaceInterface190 **intf, uint8_t bmReqType, uint8_t bReq,
                             uint16_t wVal, uint16_t wIdx, void *data, uint16_t wLen) {
    IOUSBDevRequestTO req;
    memset(&req, 0, sizeof(req));
    req.bmRequestType     = bmReqType;
    req.bRequest          = bReq;
    req.wValue            = wVal;
    req.wIndex            = wIdx;
    req.wLength           = wLen;
    req.pData             = data;
    req.noDataTimeout     = 1000;
    req.completionTimeout = 1000;
    IOReturn rc = (*intf)->ControlRequestTO(intf, 0, &req);
    if (rc != kIOReturnSuccess) return -1;
    return (int)req.wLenDone;
}

static int validate_probe_response(const uint8_t *resp, int resp_len, const stream_mode_t *mode,
                                   size_t expected_frame_bytes, uint32_t *out_max_payload, uint32_t *out_clock_hz) {
    if (!resp || resp_len < 26) return -1;
    uint8_t got_fmt = resp[2];
    uint8_t got_frm = resp[3];
    uint32_t got_max_frame = 0, got_max_payload = 0;
    memcpy(&got_max_frame, &resp[18], 4);
    memcpy(&got_max_payload, &resp[22], 4);
    if (got_fmt != mode->fmt_idx || got_frm != mode->frm_idx || (size_t)got_max_frame != expected_frame_bytes) {
        fprintf(stderr, "uvc_bulk_helper: negotiated fmt=%u frm=%u maxFrame=%u != expected %u/%u/%zu (check 10Gbps USB link)\n",
                got_fmt, got_frm, got_max_frame, mode->fmt_idx, mode->frm_idx, expected_frame_bytes);
        return -2;
    }
    *out_max_payload = (got_max_payload >= 64 && got_max_payload <= URB_BYTES) ? got_max_payload : DEFAULT_SLICE_BYTES;
    uint32_t clk = 27000000u;
    if (resp_len >= 34) {
        uint32_t raw_clk = 0;
        memcpy(&raw_clk, &resp[26], 4);
        if (raw_clk >= 1000000u && raw_clk <= 200000000u) clk = raw_clk;
    }
    *out_clock_hz = clk;
    return 0;
}

static int negotiate_uvc_mode(IOUSBInterfaceInterface190 **intf, const stream_mode_t *mode,
                              size_t expected_frame_bytes, uint32_t *out_max_payload, uint32_t *out_clock_hz) {
    uint8_t ctrl[34];
    memset(ctrl, 0, sizeof(ctrl));
    ctrl[0] = 0x01;
    ctrl[2] = mode->fmt_idx;
    ctrl[3] = mode->frm_idx;
    memcpy(&ctrl[4], &mode->interval_100ns, 4);

    if (uvc_ctrl_transfer(intf, 0x21, 0x01, 0x0100, STREAM_INTERFACE, ctrl, 26) < 0) {
        return -1;
    }
    uint8_t resp[34];
    memset(resp, 0, sizeof(resp));
    int n = uvc_ctrl_transfer(intf, 0xA1, 0x81, 0x0100, STREAM_INTERFACE, resp, 34);
    if (n < 26) {
        n = uvc_ctrl_transfer(intf, 0xA1, 0x81, 0x0100, STREAM_INTERFACE, resp, 26);
    }
    if (validate_probe_response(resp, n, mode, expected_frame_bytes, out_max_payload, out_clock_hz) != 0) {
        return -3;
    }
    uint16_t commit_len = (n >= 34) ? 34 : 26;
    if (uvc_ctrl_transfer(intf, 0x21, 0x01, 0x0200, STREAM_INTERFACE, resp, commit_len) < 0) {
        return -2;
    }
    return 0;
}

static int find_pipe_ref(IOUSBInterfaceInterface190 **intf, uint8_t target_addr, UInt8 target_type, UInt8 *out_pipe_ref) {
    UInt8 num_ep = 0;
    if ((*intf)->GetNumEndpoints(intf, &num_ep) != kIOReturnSuccess) return -1;
    for (UInt8 p = 1; p <= num_ep; p++) {
        UInt8 dir = 0, num = 0, xfer_type = 0, interval = 0;
        UInt16 mps = 0;
        if ((*intf)->GetPipeProperties(intf, p, &dir, &num, &xfer_type, &mps, &interval) == kIOReturnSuccess) {
            uint8_t addr = (uint8_t)((dir == kUSBIn ? 0x80 : 0x00) | (num & 0x0f));
            if (addr == target_addr && xfer_type == target_type) {
                *out_pipe_ref = p;
                return 0;
            }
        }
    }
    return -1;
}

typedef struct {
    helper_ctx_t *ctx;
    IOUSBInterfaceInterface190 **aud_intf;
    UInt8 pipe_ref;
    UInt64 *next_frame;
    uint8_t buf[AUDIO_ISOC_FRAMES * AUDIO_ISOC_MPS];
    IOUSBIsocFrame flist[AUDIO_ISOC_FRAMES];
} audio_isoc_slot_t;

static void audio_isoc_cb(void *refcon, IOReturn result, void *arg0) {
    (void)arg0;
    audio_isoc_slot_t *a = (audio_isoc_slot_t *)refcon;
    if (!atomic_load(&g_running) || result == kIOReturnAborted ||
        result == kIOReturnNoDevice || result == kIOReturnNotResponding) {
        atomic_fetch_sub(&a->ctx->audio_in_flight, 1);
        return;
    }

    uint8_t pkt[8 + AUDIO_ISOC_FRAMES * AUDIO_ISOC_MPS];
    uint32_t pcm_len = 0;
    for (int i = 0; i < AUDIO_ISOC_FRAMES; i++) {
        UInt16 act = a->flist[i].frActCount;
        IOReturn fst = a->flist[i].frStatus;
        if ((fst == kIOReturnSuccess || fst == kIOReturnUnderrun) && act >= 4 && act <= AUDIO_ISOC_MPS) {
            uint32_t aligned = (uint32_t)(act & ~3u); // 4-byte S16LE stereo frame alignment
            if (aligned > 0) {
                memcpy(pkt + 8 + pcm_len, a->buf + i * AUDIO_ISOC_MPS, aligned);
                pcm_len += aligned;
            }
        }
        a->flist[i].frReqCount = AUDIO_ISOC_MPS;
        a->flist[i].frActCount = 0;
        a->flist[i].frStatus   = kIOReturnError;
    }

    if (pcm_len > 0) {
        uint32_t magic = AUDIO_MAGIC;
        memcpy(pkt, &magic, 4);
        memcpy(pkt + 4, &pcm_len, 4);
        if (write_full(a->ctx->out_fd, pkt, 8 + pcm_len) != 0) {
            atomic_fetch_sub(&a->ctx->audio_in_flight, 1);
            atomic_store(&g_running, 0);
            if (g_main_rl) CFRunLoopStop(g_main_rl);
            return;
        }
    }

    UInt64 cur_bus = 0;
    AbsoluteTime at = {0, 0};
    if ((*a->aud_intf)->GetBusFrameNumber(a->aud_intf, &cur_bus, &at) == kIOReturnSuccess) {
        if (*a->next_frame < cur_bus + 4) {
            *a->next_frame = cur_bus + 4;
        }
    }
    UInt64 start_f = *a->next_frame;
    *a->next_frame += AUDIO_ISOC_FRAMES;
    IOReturn isrc = (*a->aud_intf)->ReadIsochPipeAsync(a->aud_intf, a->pipe_ref, a->buf, start_f,
                                                       AUDIO_ISOC_FRAMES, a->flist, audio_isoc_cb, a);
    if (isrc != kIOReturnSuccess) {
        // Advance schedule and retry once if start_f fell behind the USB bus frame counter
        start_f = *a->next_frame + 4;
        *a->next_frame = start_f + AUDIO_ISOC_FRAMES;
        isrc = (*a->aud_intf)->ReadIsochPipeAsync(a->aud_intf, a->pipe_ref, a->buf, start_f,
                                                  AUDIO_ISOC_FRAMES, a->flist, audio_isoc_cb, a);
        if (isrc != kIOReturnSuccess) {
            int rem = atomic_fetch_sub(&a->ctx->audio_in_flight, 1) - 1;
            if (rem <= 0) {
                fprintf(stderr, "uvc_bulk_helper: all audio isoch slots retired (0x%08x)\n", (unsigned)isrc);
            }
        }
    }
}

static bool setup_uac_audio(IOUSBInterfaceInterface190 **aud_intf, UInt8 *out_pipe_ref, CFRunLoopSourceRef *out_src) {
    if (!aud_intf) return false;
    if ((*aud_intf)->SetAlternateInterface(aud_intf, 1) != kIOReturnSuccess) {
        fprintf(stderr, "uvc_bulk_helper: SetAlternateInterface(5, 1) failed\n");
        return false;
    }
    // UAC 1.0 SET_CUR SAMPLING_FREQ_CONTROL (48,000 Hz = 0x00BB80) on Endpoint 0x86
    uint8_t rate_le[3] = { 0x80, 0xBB, 0x00 };
    uvc_ctrl_transfer(aud_intf, 0x22, 0x01, 0x0100, AUDIO_IN_EP, rate_le, 3);

    if (find_pipe_ref(aud_intf, AUDIO_IN_EP, kUSBIsoc, out_pipe_ref) != 0) {
        fprintf(stderr, "uvc_bulk_helper: Isoch IN 0x86 pipe not found\n");
        return false;
    }
    if ((*aud_intf)->CreateInterfaceAsyncEventSource(aud_intf, out_src) != kIOReturnSuccess || !*out_src) {
        return false;
    }
    return true;
}

typedef struct {
    helper_ctx_t *ctx;
    IOUSBInterfaceInterface190 **intf;
    UInt8 pipe_ref;
    uint8_t *buf;
} urb_slot_t;

static void bulk_async_cb(void *refcon, IOReturn result, void *arg0) {
    urb_slot_t *u = (urb_slot_t *)refcon;
    size_t nbytes = (size_t)(uintptr_t)arg0;

    if ((result == kIOReturnSuccess || result == kIOReturnUnderrun) && nbytes > 0) {
        parse_uvc_urb(u->ctx, u->buf, nbytes);
    }

    // Any Aborted/NoDevice/NotResponding while we did NOT request shutdown means USB disconnected.
    if (!atomic_load(&g_running) || result == kIOReturnAborted ||
        result == kIOReturnNoDevice || result == kIOReturnNotResponding) {
        int rem = atomic_fetch_sub(&u->ctx->urbs_in_flight, 1) - 1;
        if (atomic_load(&g_running) || rem <= 0) {
            atomic_store(&g_running, 0);
            if (g_main_rl) CFRunLoopStop(g_main_rl);
        }
        return;
    }

    if (result == kIOUSBPipeStalled) {
        (*u->intf)->ClearPipeStallBothEnds(u->intf, u->pipe_ref);
    } else if (result != kIOReturnSuccess && result != kIOReturnUnderrun) {
        // Brief backoff on unexpected transient error to prevent hot spin
        usleep(2000);
    }

    IOReturn s = (*u->intf)->ReadPipeAsync(u->intf, u->pipe_ref, u->buf, URB_BYTES, bulk_async_cb, u);
    if (s != kIOReturnSuccess) {
        atomic_fetch_sub(&u->ctx->urbs_in_flight, 1);
        atomic_store(&g_running, 0);
        if (g_main_rl) CFRunLoopStop(g_main_rl);
    }
}

static int run_stream(const stream_mode_t *mode) {
    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    client_hello_t hello;
    if (read_full(STDIN_FILENO, &hello, sizeof(hello)) != 0 ||
        hello.magic != HELLO_MAGIC || (hello.version & 0xFFFFu) != 1 || hello.ring_slots != RING_SLOTS) {
        fprintf(stderr, "uvc_bulk_helper: invalid client handshake\n");
        return 10;
    }
    bool want_audio = (hello.version & HELLO_FLAG_AUDIO) != 0;

    helper_ctx_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.width = mode->width;
    ctx.height = mode->height;
    ctx.expected_frame_bytes = (size_t)mode->width * (size_t)mode->height * 3ULL / 2ULL;
    ctx.clock_hz = 27000000u;
    ctx.cur_slot = -1;
    ctx.last_fid = -1;
    ctx.out_fd = STDOUT_FILENO;
    ctx.client_pid = hello.client_pid;
    ctx.on_frame = emit_frame_to_pipe;
    mach_timebase_info(&ctx.tb);
    if (ctx.tb.numer > 0) {
        ctx.last_deliv_mach = (14700000ULL * (uint64_t)ctx.tb.denom) / (uint64_t)ctx.tb.numer;
    }

    for (int i = 0; i < RING_SLOTS; i++) {
        ctx.surfaces[i] = create_nv12_surface(ctx.width, ctx.height);
        if (!ctx.surfaces[i]) {
            fprintf(stderr, "uvc_bulk_helper: IOSurface allocation failed\n");
            for (int j = 0; j < i; j++) CFRelease(ctx.surfaces[j]);
            return 11;
        }
    }

    bool used_device_capture = false;
    IOUSBInterfaceInterface190 **aud_intf = NULL;
    IOUSBInterfaceInterface190 **intf = claim_stream_interfaces(want_audio, &used_device_capture, &aud_intf, &ctx.usb_speed);
    if (!intf) {
        for (int i = 0; i < RING_SLOTS; i++) CFRelease(ctx.surfaces[i]);
        return 13;
    }

    uint32_t max_payload = DEFAULT_SLICE_BYTES;
    if (negotiate_uvc_mode(intf, mode, ctx.expected_frame_bytes, &max_payload, &ctx.clock_hz) != 0) {
        fprintf(stderr, "uvc_bulk_helper: UVC mode negotiation failed\n");
        if (aud_intf) { (*aud_intf)->USBInterfaceClose(aud_intf); (*aud_intf)->Release(aud_intf); }
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        if (used_device_capture) run_recover();
        for (int i = 0; i < RING_SLOTS; i++) CFRelease(ctx.surfaces[i]);
        return 14;
    }
    ctx.max_payload_bytes = max_payload;

    UInt8 pipe_ref = 0;
    if (find_pipe_ref(intf, BULK_IN_EP, kUSBBulk, &pipe_ref) != 0) {
        fprintf(stderr, "uvc_bulk_helper: Bulk IN 0x82 pipe not found\n");
        if (aud_intf) { (*aud_intf)->USBInterfaceClose(aud_intf); (*aud_intf)->Release(aud_intf); }
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        if (used_device_capture) run_recover();
        for (int i = 0; i < RING_SLOTS; i++) CFRelease(ctx.surfaces[i]);
        return 15;
    }
    (*intf)->ClearPipeStallBothEnds(intf, pipe_ref);

    UInt8 aud_pipe_ref = 0;
    CFRunLoopSourceRef aud_src = NULL;
    bool audio_ready = false;
    if (aud_intf) {
        audio_ready = setup_uac_audio(aud_intf, &aud_pipe_ref, &aud_src);
        if (!audio_ready) {
            (*aud_intf)->USBInterfaceClose(aud_intf);
            (*aud_intf)->Release(aud_intf);
            aud_intf = NULL;
        }
    }

    if (send_ring_ports_to_client(&ctx, hello.client_pid, hello.nonce) != 0) {
        if (aud_src) CFRelease(aud_src);
        if (aud_intf) { (*aud_intf)->USBInterfaceClose(aud_intf); (*aud_intf)->Release(aud_intf); }
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        if (used_device_capture) run_recover();
        for (int i = 0; i < RING_SLOTS; i++) CFRelease(ctx.surfaces[i]);
        return 16;
    }

    server_ready_t ready;
    ready.magic        = READY_MAGIC;
    ready.width        = ctx.width;
    ready.height       = ctx.height;
    ready.pixel_format = PIXEL_FMT_NV12;
    ready.ring_slots   = RING_SLOTS;
    ready.usb_speed    = ctx.usb_speed
                       | (audio_ready ? READY_FLAG_AUDIO : 0u)
                       | (used_device_capture ? READY_FLAG_CAPTURED : 0u);
    if (write_full(STDOUT_FILENO, &ready, sizeof(ready)) != 0) {
        if (aud_src) CFRelease(aud_src);
        if (aud_intf) { (*aud_intf)->USBInterfaceClose(aud_intf); (*aud_intf)->Release(aud_intf); }
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        if (used_device_capture) run_recover();
        for (int i = 0; i < RING_SLOTS; i++) CFRelease(ctx.surfaces[i]);
        return 17;
    }

    CFRunLoopSourceRef usb_src = NULL;
    if ((*intf)->CreateInterfaceAsyncEventSource(intf, &usb_src) != kIOReturnSuccess || !usb_src) {
        if (aud_src) CFRelease(aud_src);
        if (aud_intf) { (*aud_intf)->USBInterfaceClose(aud_intf); (*aud_intf)->Release(aud_intf); }
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        if (used_device_capture) run_recover();
        for (int i = 0; i < RING_SLOTS; i++) CFRelease(ctx.surfaces[i]);
        return 18;
    }
    g_main_rl = CFRunLoopGetCurrent();
    CFRunLoopAddSource(g_main_rl, usb_src, kCFRunLoopDefaultMode);
    if (audio_ready && aud_src) {
        CFRunLoopAddSource(g_main_rl, aud_src, kCFRunLoopDefaultMode);
    }

    pthread_t watch_th;
    pthread_create(&watch_th, NULL, client_watch_thread, &ctx);

    audio_isoc_slot_t aud_slots[AUDIO_ISOC_XFERS];
    UInt64 next_aud_frame = 0;
    if (audio_ready && aud_intf) {
        memset(aud_slots, 0, sizeof(aud_slots));
        UInt64 cur_bus = 0;
        AbsoluteTime at = {0, 0};
        (*aud_intf)->GetBusFrameNumber(aud_intf, &cur_bus, &at);
        next_aud_frame = cur_bus + 6;
        for (int i = 0; i < AUDIO_ISOC_XFERS; i++) {
            aud_slots[i].ctx        = &ctx;
            aud_slots[i].aud_intf   = aud_intf;
            aud_slots[i].pipe_ref   = aud_pipe_ref;
            aud_slots[i].next_frame = &next_aud_frame;
            for (int j = 0; j < AUDIO_ISOC_FRAMES; j++) {
                aud_slots[i].flist[j].frReqCount = AUDIO_ISOC_MPS;
                aud_slots[i].flist[j].frActCount = 0;
                aud_slots[i].flist[j].frStatus   = kIOReturnError;
            }
            UInt64 sf = next_aud_frame;
            next_aud_frame += AUDIO_ISOC_FRAMES;
            atomic_fetch_add(&ctx.audio_in_flight, 1);
            if ((*aud_intf)->ReadIsochPipeAsync(aud_intf, aud_pipe_ref, aud_slots[i].buf, sf,
                                                AUDIO_ISOC_FRAMES, aud_slots[i].flist, audio_isoc_cb, &aud_slots[i]) != kIOReturnSuccess) {
                atomic_fetch_sub(&ctx.audio_in_flight, 1);
            }
        }
    }

    urb_slot_t urbs[NUM_URBS];
    memset(urbs, 0, sizeof(urbs));
    int submitted = 0;
    for (int i = 0; i < NUM_URBS; i++) {
        urbs[i].ctx      = &ctx;
        urbs[i].intf     = intf;
        urbs[i].pipe_ref = pipe_ref;
        if (posix_memalign((void **)&urbs[i].buf, 4096, URB_BYTES) != 0) {
            urbs[i].buf = malloc(URB_BYTES);
        }
        if (!urbs[i].buf) break;
        atomic_fetch_add(&ctx.urbs_in_flight, 1);
        if ((*intf)->ReadPipeAsync(intf, pipe_ref, urbs[i].buf, URB_BYTES, bulk_async_cb, &urbs[i]) == kIOReturnSuccess) {
            submitted++;
        } else {
            atomic_fetch_sub(&ctx.urbs_in_flight, 1);
        }
    }
    if (submitted == 0) {
        fprintf(stderr, "uvc_bulk_helper: initial ReadPipeAsync submission failed\n");
        atomic_store(&g_running, 0);
    }

    while (atomic_load(&g_running) && !g_stop_signal) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.10, false);
    }

    atomic_store(&g_running, 0);
    if (audio_ready && aud_intf) {
        (*aud_intf)->AbortPipe(aud_intf, aud_pipe_ref);
    }
    (*intf)->AbortPipe(intf, pipe_ref);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    if (audio_ready && aud_src) {
        CFRunLoopRemoveSource(g_main_rl, aud_src, kCFRunLoopDefaultMode);
        CFRelease(aud_src);
    }
    CFRunLoopRemoveSource(g_main_rl, usb_src, kCFRunLoopDefaultMode);
    CFRelease(usb_src);

    release_active_slot_lock(&ctx);
    if (aud_intf) {
        (*aud_intf)->SetAlternateInterface(aud_intf, 0);
        (*aud_intf)->USBInterfaceClose(aud_intf);
        (*aud_intf)->Release(aud_intf);
    }
    (*intf)->USBInterfaceClose(intf);
    (*intf)->Release(intf);
    if (used_device_capture) {
        run_recover();
    }

    for (int i = 0; i < NUM_URBS; i++) {
        free(urbs[i].buf);
    }
    for (int i = 0; i < RING_SLOTS; i++) {
        if (ctx.surfaces[i]) CFRelease(ctx.surfaces[i]);
    }

    // Wake watcher thread if still blocked (closing stdin) and join
    close(STDIN_FILENO);
    pthread_join(watch_th, NULL);
    return 0;
}

// ---------------- Offline Deterministic Self-Test (--selftest, No Root / No USB) ----------------

static int g_selftest_emitted = 0;
static int g_selftest_last_slot = -1;
static uint64_t g_selftest_last_pts = 0;
static uint64_t g_selftest_last_arr = 0;

static void selftest_emit(helper_ctx_t *ctx, int slot, uint64_t pts_mach, uint64_t arrival_mach) {
    (void)ctx;
    g_selftest_emitted++;
    g_selftest_last_slot = slot;
    g_selftest_last_pts  = pts_mach;
    g_selftest_last_arr  = arrival_mach;
}

static int run_selftest(void) {
    // 1. Test coalesced UVC 16KB slice stripping + padded NV12 stride + 32-bit 27MHz PTS/STC wraparound
    const uint32_t W = 64, H = 36;
    const size_t y_bytes = (size_t)W * H;             // 2304
    const size_t uv_bytes = (size_t)W * (H / 2);      // 1152
    const size_t frame_bytes = y_bytes + uv_bytes;    // 3456
    const size_t y_bpr = 128, uv_bpr = 128;           // padded stride (> 64)

    uint8_t y_plane[128 * 36];
    uint8_t uv_plane[128 * 18];
    memset(y_plane, 0xAA, sizeof(y_plane));
    memset(uv_plane, 0xBB, sizeof(uv_plane));

    helper_ctx_t ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.is_selftest = true;
    ctx.width = W;
    ctx.height = H;
    ctx.expected_frame_bytes = frame_bytes;
    ctx.max_payload_bytes = 1024; // 1024-byte slices (12B header + 1012B payload)
    ctx.usb_speed = 5;
    ctx.cur_slot = -1;
    ctx.last_fid = -1;
    ctx.on_frame = selftest_emit;
    ctx.cur_dest.y_base  = y_plane;
    ctx.cur_dest.uv_base = uv_plane;
    ctx.cur_dest.width   = W;
    ctx.cur_dest.height  = H;
    ctx.cur_dest.y_bpr   = y_bpr;
    ctx.cur_dest.uv_bpr  = uv_bpr;
    mach_timebase_info(&ctx.tb);

    // Mark slots 0 and 1 busy so allocator must pick slot 2!
    ctx.mock_in_use[0] = true;
    atomic_store(&ctx.pending_ack[1], 1);

    // Build expected logical NV12 pattern
    uint8_t expected[3456];
    for (size_t i = 0; i < frame_bytes; i++) {
        expected[i] = (uint8_t)((i * 7 + 3) & 0xFF);
    }

    // Pack into a single coalesced URB with 1024B slices and 27 MHz wraparound across 0xFFFFFFFF:
    // PTS = 0xFFFFFF00, final STC = 0xFFFFFF00 + 392310 (~14.53 ms = 0x0005FC16)
    uint32_t pts = 0xFFFFFF00u;
    uint32_t stc_eof = pts + 392310u; // wraps past 2^32!
    uint8_t urb[8192];
    size_t uoff = 0, foff = 0;
    while (foff < frame_bytes) {
        size_t pay = frame_bytes - foff;
        if (pay > 1012) pay = 1012;
        int is_eof = ((foff + pay) == frame_bytes) ? 1 : 0;
        uint32_t stc = is_eof ? stc_eof : (pts + 1000u);
        urb[uoff + 0] = 12;
        urb[uoff + 1] = (uint8_t)(0x80 | 0x08 | 0x04 | (is_eof ? 0x02 : 0x00) | 0x01);
        memcpy(urb + uoff + 2, &pts, 4);
        memcpy(urb + uoff + 6, &stc, 4);
        urb[uoff + 10] = 0;
        urb[uoff + 11] = 0;
        memcpy(urb + uoff + 12, expected + foff, pay);
        uoff += 12 + pay;
        foff += pay;
    }

    g_selftest_emitted = 0;
    parse_uvc_urb(&ctx, urb, uoff);

    if (g_selftest_emitted != 1 || g_selftest_last_slot != 2) {
        fprintf(stderr, "SELFTEST FAIL: emitted=%d slot=%d (expected 1, 2)\n", g_selftest_emitted, g_selftest_last_slot);
        return 1;
    }

    // Verify padded stride integrity on both Y and UV planes (and padding bytes untouched!)
    for (size_t r = 0; r < H; r++) {
        if (memcmp(y_plane + r * y_bpr, expected + r * W, W) != 0) {
            fprintf(stderr, "SELFTEST FAIL: Y row %zu mismatch\n", r);
            return 1;
        }
        if (y_plane[r * y_bpr + W] != 0xAA) {
            fprintf(stderr, "SELFTEST FAIL: Y padding clobbered at row %zu\n", r);
            return 1;
        }
    }
    for (size_t r = 0; r < H / 2; r++) {
        if (memcmp(uv_plane + r * uv_bpr, expected + y_bytes + r * W, W) != 0) {
            fprintf(stderr, "SELFTEST FAIL: UV row %zu mismatch\n", r);
            return 1;
        }
        if (uv_plane[r * uv_bpr + W] != 0xBB) {
            fprintf(stderr, "SELFTEST FAIL: UV padding clobbered at row %zu\n", r);
            return 1;
        }
    }

    // Verify 32-bit 27MHz wraparound gave ~14.5 ms delivery delta
    uint64_t delta_ns = (g_selftest_last_arr - g_selftest_last_pts) * ctx.tb.numer / ctx.tb.denom;
    double delta_ms = (double)delta_ns / 1e6;
    if (delta_ms < 14.4 || delta_ms > 15.2) {
        fprintf(stderr, "SELFTEST FAIL: wraparound delivery delta=%.3f ms (expected ~14.53 ms)\n", delta_ms);
        return 1;
    }

    // 2. Verify corrupt frame (UVC ERR bit 0x40) is rejected and NOT emitted
    urb[1] |= 0x40;     // set UVC error bit on first slice
    urb[1] ^= 0x01;     // flip FID
    parse_uvc_urb(&ctx, urb, uoff);
    if (g_selftest_emitted != 1) {
        fprintf(stderr, "SELFTEST FAIL: corrupt frame was emitted\n");
        return 1;
    }

    // 3. Verify VS_PROBE response validation rejects wrong frame size / format and accepts valid 34B probe
    uint8_t good_probe[34];
    memset(good_probe, 0, sizeof(good_probe));
    good_probe[2] = kModes[0].fmt_idx;
    good_probe[3] = kModes[0].frm_idx;
    uint32_t exp4k = 3840u * 2160u * 3u / 2u;
    uint32_t mp = 16384u, clk = 27000000u, out_mp = 0, out_clk = 0;
    memcpy(&good_probe[18], &exp4k, 4);
    memcpy(&good_probe[22], &mp, 4);
    memcpy(&good_probe[26], &clk, 4);
    if (validate_probe_response(good_probe, 34, &kModes[0], exp4k, &out_mp, &out_clk) != 0 ||
        out_mp != 16384u || out_clk != 27000000u) {
        fprintf(stderr, "SELFTEST FAIL: valid probe rejected\n");
        return 1;
    }
    uint32_t wrong_sz = 1920u * 1080u * 3u / 2u;
    memcpy(&good_probe[18], &wrong_sz, 4);
    if (validate_probe_response(good_probe, 34, &kModes[0], exp4k, &out_mp, &out_clk) == 0) {
        fprintf(stderr, "SELFTEST FAIL: mismatched dwMaxVideoFrameSize was accepted\n");
        return 1;
    }

    // 4. Verify uninitiated kIOReturnAborted in bulk_async_cb stops the loop cleanly
    atomic_store(&g_running, 1);
    atomic_store(&ctx.urbs_in_flight, 1);
    urb_slot_t dummy_urb = { &ctx, NULL, 0, NULL };
    bulk_async_cb(&dummy_urb, kIOReturnAborted, 0);
    if (atomic_load(&g_running) != 0 || atomic_load(&ctx.urbs_in_flight) != 0) {
        fprintf(stderr, "SELFTEST FAIL: kIOReturnAborted did not stop helper loop\n");
        return 1;
    }
    atomic_store(&g_running, 1);

    // 5. Verify real IOSurface NV12 creation succeeds without root
    IOSurfaceRef surf = create_nv12_surface(1920, 1080);
    if (!surf || IOSurfaceGetPlaneCount(surf) != 2) {
        fprintf(stderr, "SELFTEST FAIL: create_nv12_surface failed\n");
        if (surf) CFRelease(surf);
        return 1;
    }
    CFRelease(surf);

    printf("uvc_bulk_helper selftest: PASS (stride, wraparound %.2f ms, slot lease, err discard, IOSurface)\n", delta_ms);
    return 0;
}

static int verify_system_dylibs_only(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header *hdr = _dyld_get_image_header(i);
        if (hdr && hdr->filetype == MH_EXECUTE) continue;
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strncmp(name, "/System/", 8) != 0 && strncmp(name, "/usr/lib/", 9) != 0) {
            fprintf(stderr, "security error: non-system library loaded: %s\n", name);
            return -1;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    // Scrub dynamic loader environment variables as defense-in-depth
    unsetenv("DYLD_INSERT_LIBRARIES");
    unsetenv("DYLD_LIBRARY_PATH");
    unsetenv("DYLD_FRAMEWORK_PATH");
    if (verify_system_dylibs_only() != 0) {
        return 78;
    }

    if (argc == 1) {
        return run_stream(&kModes[0]);
    }
    if (argc == 2 && strcmp(argv[1], "--recover") == 0) {
        return run_recover();
    }
    if (argc == 2 && strcmp(argv[1], "--selftest") == 0) {
        return run_selftest();
    }
    if (argc == 3 && strcmp(argv[1], "--mode") == 0) {
        for (size_t i = 0; i < sizeof(kModes) / sizeof(kModes[0]); i++) {
            if (strcmp(argv[2], kModes[i].name) == 0) {
                return run_stream(&kModes[i]);
            }
        }
    }

    fprintf(stderr, "usage: %s [--mode 4k60|4k30|2k60|1080p60 | --recover | --selftest]\n", argv[0]);
    return 64;
}
