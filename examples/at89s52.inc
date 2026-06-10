; at89s52.inc — extra SFRs of the 8052/AT89S52 (timer 2)
; The core 8051 SFRs are predefined by zinc51 itself.

T2CON   data    0C8h
T2MOD   data    0C9h
RCAP2L  data    0CAh
RCAP2H  data    0CBh
TL2     data    0CCh
TH2     data    0CDh

; T2CON bits
TF2     bit     0CFh
EXF2    bit     0CEh
RCLK    bit     0CDh
TCLK    bit     0CCh
EXEN2   bit     0CBh
TR2     bit     0CAh

; IE bit
ET2     bit     0ADh
