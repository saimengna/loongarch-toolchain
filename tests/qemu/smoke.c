#include <stdio.h>
#include <string.h>

int main(void)
{
    char buffer[32];
    const char *message = "qemu-smoke-ok";
    volatile unsigned long x = 6;
    volatile unsigned long y = 7;

    memcpy(buffer, message, strlen(message) + 1);
    if (strcmp(buffer, message) != 0)
        return 1;
    if (x * y != 42)
        return 2;

    puts(buffer);
    return 0;
}
