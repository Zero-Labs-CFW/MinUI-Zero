/* fpslog.so -- LD_PRELOAD present-rate + pacing counter. Firmware-agnostic frame-hold capture:
 * hooks BOTH present calls (Zero=SDL_RenderPresent, NextUI=SDL_GL_SwapWindow) and once per second
 * appends to $FPSLOG_PATH:
 *   "<t> render=<R> swap=<S> maxgap_ms=<G> late=<L>"
 * R/S = presents per second via each call (Zero->render, NextUI->swap). G = the longest interval
 * between consecutive presents that second (worst hitch). L = presents that arrived >25 ms after
 * the previous one (>1.5x a 60 Hz frame = at least one missed vblank = a visible stutter).
 * The FIRST call of EACH hook is logged separately:
 *   "first_present render uptime=<U> mono=<T>"   /   "first_present swap uptime=<U> mono=<T>"
 * because NextUI draws its loading screen through SDL_RenderPresent before the game starts
 * presenting through SDL_GL_SwapWindow; launch->first-GAME-frame is the swap line there and the
 * render line on Zero. uptime is /proc/uptime, the same clock the harness stamps launch_up with.
 * Present rate == emulation fps for vsync 60 Hz content with ~0 dupes (Zero logs dup/s in MEASURE;
 * a skipped dupe on Zero shows as a 33 ms gap, so read G/L there alongside dup/s).
 * A dlsym failure is reported LOUDLY on stderr (lands in the game log) instead of swallowing. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>

static double now_s(void){ struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return ts.tv_sec + ts.tv_nsec/1e9; }
static FILE* out(void){
  static FILE* f=NULL; static int tried=0;
  if(!f && !tried){ tried=1; const char* p=getenv("FPSLOG_PATH"); f=fopen(p&&*p?p:"/tmp/fpslog.txt","a"); if(f) setvbuf(f,NULL,_IOLBF,0); }
  return f;
}
static void log_first(const char* kind, double t){
  FILE* o=out(); if(!o) return;
  double u=-1; FILE* up=fopen("/proc/uptime","r");
  if(up){ if(fscanf(up,"%lf",&u)!=1) u=-1; fclose(up); }
  fprintf(o,"first_present %s uptime=%.2f mono=%.3f\n",kind,u,t);
}
static unsigned long c_render=0, c_swap=0, late=0;
static double t0=-1, last_t=-1, maxgap=0;
static void tick(void){
  double t=now_s();
  if(last_t>=0){ double g=t-last_t; if(g>maxgap) maxgap=g; if(g>0.025) late++; }
  last_t=t;
  if(t0<0){ t0=t; return; }
  if(t-t0>=1.0){
    FILE* o=out();
    if(o) fprintf(o,"%.3f render=%.2f swap=%.2f maxgap_ms=%.1f late=%lu\n", t, c_render/(t-t0), c_swap/(t-t0), maxgap*1000.0, late);
    c_render=0; c_swap=0; maxgap=0; late=0; t0=t;
  }
}
static void* resolve(const char* name){
  void* p=dlsym(RTLD_NEXT,name);
  if(!p) fprintf(stderr,"fpslog: dlsym(%s) FAILED -- present call NOT forwarded, run is INVALID\n",name);
  return p;
}
void SDL_RenderPresent(void* r){
  static void(*real)(void*)=NULL; static int tried=0, first=1;
  if(!real && !tried){ tried=1; real=(void(*)(void*))resolve("SDL_RenderPresent"); }
  if(first){ first=0; log_first("render", now_s()); }
  c_render++; tick();
  if(real) real(r);
}
void SDL_GL_SwapWindow(void* w){
  static void(*real)(void*)=NULL; static int tried=0, first=1;
  if(!real && !tried){ tried=1; real=(void(*)(void*))resolve("SDL_GL_SwapWindow"); }
  if(first){ first=0; log_first("swap", now_s()); }
  c_swap++; tick();
  if(real) real(w);
}
