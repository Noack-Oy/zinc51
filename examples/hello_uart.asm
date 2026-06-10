; hello_uart.asm — print a string on the serial port
; 9600 baud, 8N1, 11.0592 MHz crystal

        org     0000h
        ljmp    main

        org     0030h
main:   mov     tmod, #20h      ; timer 1, mode 2 (8-bit auto reload)
        mov     th1, #0FDh      ; 9600 baud
        setb    tr1
        mov     scon, #50h      ; mode 1, receive enabled
        mov     dptr, #msg
next:   clr     a
        movc    a, @a+dptr
        jz      done
        acall   putc
        inc     dptr
        sjmp    next
done:   sjmp    $

putc:   mov     sbuf, a
wait:   jnb     ti, wait
        clr     ti
        ret

msg:    db      'Hello, 8051!', 0Dh, 0Ah, 0

        end
