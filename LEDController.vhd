-- LEDController.VHD
-- 2025.03.09
--
-- This SCOMP peripheral drives ten outputs high or low based on
-- a value from SCOMP.

LIBRARY IEEE;
LIBRARY LPM;

USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;
USE LPM.LPM_COMPONENTS.ALL;

ENTITY LEDController IS
    PORT(
        CS          : IN  STD_LOGIC;                             -- Chip Select
        WRITE_EN    : IN  STD_LOGIC;                             -- Write Enable
        RESETN      : IN  STD_LOGIC;                             -- Active-low Reset
        CLK         : IN  STD_LOGIC;                             -- Clock signal
        LEDs        : OUT STD_LOGIC_VECTOR(9 DOWNTO 0);          -- 10 LEDs controlled by PWM
        IO_DATA     : IN  STD_LOGIC_VECTOR(15 DOWNTO 0)          -- Data from SCOMP
    );
END LEDController;

ARCHITECTURE a OF LEDController IS
    signal compare_val : STD_LOGIC_VECTOR(7 downto 0) := "10000000"; -- Default 50% duty cycle (128)
    signal counter     : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
BEGIN
    -- Process 1: Handle CS and WRITE_EN (write to compare_val)
    PROCESS (CS, WRITE_EN, IO_DATA, RESETN)
    BEGIN
        IF RESETN = '0' THEN
            -- Reset compare_val to 50% on reset
            compare_val <= "10000000";
        ELSIF (CS = '1' AND WRITE_EN = '1') THEN
            -- Update compare_val with lower 8 bits of IO_DATA
            compare_val <= IO_DATA(7 DOWNTO 0);
        END IF;
    END PROCESS;

    -- Process 2: PWM Counter and LED Control (runs on CLK)
    PROCESS (CLK, RESETN)
    BEGIN
        IF RESETN = '0' THEN
            counter <= (others => '0');
            LEDs <= (others => '0');
        ELSIF RISING_EDGE(CLK) THEN
            -- Increment the counter
            IF counter = "11111111" THEN
                counter <= (others => '0');  -- Reset counter at 255
            ELSE
                counter <= counter + 1;  -- Increment counter
            END IF;

            -- PWM Logic: Control LEDs based on compare_val
            IF counter < compare_val THEN
                LEDs <= "1111111111";  -- Turn all LEDs ON
            ELSE
                LEDs <= "0000000000";  -- Turn all LEDs OFF
            END IF;
        END IF;
    END PROCESS;

END a;
