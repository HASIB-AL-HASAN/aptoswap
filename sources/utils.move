module Aptoswap::utils {

    const TIME_INTERVAL_DAY: u64 = 86400;

    struct WeeklySmaU128 has drop, store {
        start_time: u64,
        current_time: u64,

        a0: u128, a1: u128,  a2: u128,  a3: u128,  a4: u128,  a5: u128,  a6: u128,
        c0: u64, c1: u64,  c2: u64,  c3: u64,  c4: u64,  c5: u64,  c6: u64,
    }

    public fun create_sma128(): WeeklySmaU128 {
        WeeklySmaU128 {
            start_time: 0,
            current_time: 0,
            a0: 0, a1: 0, a2: 0, a3: 0, a4: 0, a5: 0, a6: 0,
            c0: 0, c1: 0, c2: 0, c3: 0, c4: 0, c5: 0, c6: 0,
        }
    }

    public fun add_sma128(sma: &mut WeeklySmaU128, time: u64, value: u128) {
        sma.current_time = time;

        if (sma.start_time == 0) {
            sma.start_time = time - (TIME_INTERVAL_DAY * 6);
            sma.a0 = value;
            sma.a1 = value;
            sma.a2 = value;
            sma.a3 = value;
            sma.a4 = value;
            sma.a5 = value;
            sma.a6 = 0;

            sma.c0 = 1;
            sma.c1 = 1;
            sma.c2 = 1;
            sma.c3 = 1;
            sma.c4 = 1;
            sma.c5 = 1;
            sma.c6 = 0;
        } else {
            while (sma.start_time + (TIME_INTERVAL_DAY * 7) <= time) {
                sma.start_time = sma.start_time + TIME_INTERVAL_DAY;
                sma.a0 = sma.a1;
                sma.a1 = sma.a2;
                sma.a2 = sma.a3;
                sma.a3 = sma.a4;
                sma.a4 = sma.a5;
                sma.a5 = sma.a6;
                sma.a6 = 0;

                sma.c0 = sma.c1;
                sma.c1 = sma.c2;
                sma.c2 = sma.c3;
                sma.c3 = sma.c4;
                sma.c4 = sma.c5;
                sma.c5 = sma.c6;
                sma.c6 = 0;
            };
        };

        let index = (time - sma.start_time) / TIME_INTERVAL_DAY;
        if (index == 0) {
            sma.a6 = sma.a6 + value;
            sma.c6 = sma.c6 + 1;
        }
        else if (index == 1) {
            sma.a1 = sma.a1 + value;
            sma.c1 = sma.c1 + 1;
        }
        else if (index == 2) {
            sma.a2 = sma.a2 + value;
            sma.c2 = sma.c2 + 1;
        }
        else if (index == 3) {
            sma.a3 = sma.a3 + value;
            sma.c3 = sma.c3 + 1;
        }
        else if (index == 4) {
            sma.a4 = sma.a4 + value;
            sma.c4 = sma.c4 + 1;
        }
        else if (index == 5) {
            sma.a5 = sma.a5 + value;
            sma.c5 = sma.c5 + 1;
        }
        else {
            sma.a6 = sma.a6 + value;
            sma.c6 = sma.c6 + 1;
        }
    }
}