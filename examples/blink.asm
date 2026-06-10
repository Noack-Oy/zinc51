; blink.asm — toggle an LED on P1.0 (classic 8051 @ 12 MHz)

LED     bit     P1.0

        org     0000h
        ljmp    main

        org     0030h
main:   mov     sp, #60h
loop:   cpl     LED
        mov     r2, #20
        acall   delay
        sjmp    loop

; ~25 ms per unit in R2 (12 MHz, 12 clocks per cycle)
delay:  mov     r1, #50
d1:     mov     r0, #250
d2:     djnz    r0, d2          ; 250 * 2 cycles = 500 us
        djnz    r1, d1
        djnz    r2, delay
        ret

        end
