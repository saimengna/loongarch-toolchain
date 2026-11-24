int main(void)
{
    volatile unsigned long x = 6;
    volatile unsigned long y = 7;

    return x * y == 42 ? 0 : 1;
}
