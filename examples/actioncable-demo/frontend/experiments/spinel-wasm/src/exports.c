/* The module's exports for host.js. Spinel's library mode emits the studio
   with an init function in place of main; these wrap its entries so a Ruby
   raise reaches JavaScript as host_error instead of trapping the module. */
#include "pixel_studio.h"

#define EXPORT(name) __attribute__((export_name(name)))

extern void host_error(const char *cls, const char *msg);

static void call_init(void *ctx) { (void)ctx; pixel_studio_init(); }
static void call_start(void *ctx) { (void)ctx; sp_Pixel_s_start(); }
static void call_dispatch(void *ctx) { sp_Pixel_s_dispatch(sp_box_int(*(int *)ctx)); }

static int guarded(void (*fn)(void *), void *ctx) {
  const char *cls = 0, *msg = 0;
  if (pixel_studio_init_try(fn, ctx, &cls, &msg) == 0) return 0;
  host_error(cls ? cls : "RuntimeError", msg ? msg : "");
  return 1;
}

EXPORT("init") int w_init(void) { return guarded(call_init, 0); }
EXPORT("start") int w_start(void) { return guarded(call_start, 0); }
EXPORT("dispatch") int w_dispatch(int code) { return guarded(call_dispatch, &code); }
