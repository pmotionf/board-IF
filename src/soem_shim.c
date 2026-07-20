/*
 * Workaround for a translate-c struct-layout bug: ec_smt is wrapped in
 * OSAL_PACKED_BEGIN/END (#pragma pack(push,1)/pop), which sets its
 * *exported alignment* to 1 -- not just its internal layout. translate-c's
 * generated Zig bindings replay the pragma's effect on internal layout
 * (sizeof matches) but not on exported alignment, so Zig computes
 * ec_slavet.SM at the wrong byte offset (confirmed via @offsetOf vs
 * offsetof() comparison: SM lands 3 bytes later than reality on this
 * build). The drift is not a simple constant for fields further into the
 * struct, so a hand-patched offset correction isn't safe -- SM is instead
 * accessed exclusively through these two accessors, compiled against the
 * real header, so they always use the real ABI regardless of how
 * translate-c misreads it.
 */
#include "soem/soem.h"

typedef struct
{
   uint16 addr[EC_MAXSM];
   uint16 length[EC_MAXSM];
   uint32 flags[EC_MAXSM];
   uint8 type[EC_MAXSM];
} shim_sm_t;

void shim_get_sm(ecx_contextt *ctx, uint16 slave, shim_sm_t *out)
{
   ec_slavet *s = &ctx->slavelist[slave];
   int i;
   for (i = 0; i < EC_MAXSM; i++)
   {
      out->addr[i] = etohs(s->SM[i].StartAddr);
      out->length[i] = etohs(s->SM[i].SMlength);
      out->flags[i] = etohl(s->SM[i].SMflags);
      out->type[i] = s->SMtype[i];
   }
}

void shim_set_sm(ecx_contextt *ctx, uint16 slave, uint8 idx, uint16 addr, uint16 length, uint32 flags, uint8 smtype)
{
   ec_slavet *s = &ctx->slavelist[slave];
   s->SM[idx].StartAddr = htoes(addr);
   s->SM[idx].SMlength = htoes(length);
   s->SM[idx].SMflags = htoel(flags);
   s->SMtype[idx] = smtype;
}
