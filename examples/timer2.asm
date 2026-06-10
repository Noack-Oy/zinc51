; timer2.asm — toggle P1.0 from the timer 2 interrupt (AT89S52, 12 MHz)
; Demonstrates the .include directive with a controller header file.

        .include "at89s52.inc"

RELOAD  equ     -50000          ; 50 ms at 12 MHz (16-bit auto reload)

        org     0000h
        ljmp    main

        org     002Bh           ; timer 2 interrupt vector
        ljmp    t2isr

        org     0040h
main:   mov     rcap2l, #low(RELOAD)
        mov     rcap2h, #high(RELOAD)
        setb    tr2
        setb    et2
        setb    ea
        sjmp    $

t2isr:  clr     tf2             ; not cleared by hardware in auto-reload mode
        cpl     p1.0
        reti

        end
