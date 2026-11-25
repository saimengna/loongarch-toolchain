#include <stdint.h>
#include <stdio.h>
#include <string.h>

struct pair {
  uint64_t left;
  uint64_t right;
};

typedef uint64_t (*mix_fn)(uint64_t);

static uint64_t mix(uint64_t value)
{
  value ^= value >> 17;
  value *= UINT64_C(0x9e3779b97f4a7c15);
  value ^= value >> 29;
  return value;
}

int main(void)
{
  struct pair values = { UINT64_C(0x0123456789abcdef), UINT64_C(0xfedcba9876543210) };
  mix_fn op = mix;
  char buffer[32];
  uint64_t acc = 0;

  for (unsigned int i = 0; i < 64; ++i)
    acc ^= op(values.left + i);

  values.right ^= acc;
  if ((values.right & UINT64_C(0xff)) == 0)
    return 1;

  memcpy(buffer, "tier2-ok", sizeof("tier2-ok"));
  puts(buffer);
  return 0;
}
