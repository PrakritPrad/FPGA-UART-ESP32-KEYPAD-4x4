library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity UART_TX is
    Port (
        SysClk : in  std_logic;  -- 20 MHz
        K2_COL : in  std_logic_vector(3 downto 0);
        K2_ROW : out std_logic_vector(3 downto 0);
        Tx     : out std_logic;  -- UART TX
        RelayCtl : out std_logic;
        Buzzer : out std_logic;
        RED_LED   : out std_logic;
        GREEN_LED : out std_logic
    );
end UART_TX;

architecture Behavioral of UART_TX is
    signal row_drive    : std_logic_vector(3 downto 0);
    signal key_valid    : std_logic;
    signal key_code     : std_logic_vector(3 downto 0);
    signal tx_start     : std_logic;
    signal tx_data      : std_logic_vector(7 downto 0);
    signal tx_busy      : std_logic;
begin
    scanner_i: entity work.keypad_scanner
        port map (
            clk          => SysClk,
            col_in       => K2_COL,
            row_out      => row_drive,
            frame_strobe => open,
            key_valid    => key_valid,
            key_code     => key_code
        );

    lock_i: entity work.pin_lock_fsm
        port map (
            clk       => SysClk,
            key_valid => key_valid,
            key_code  => key_code,
            uart_busy => tx_busy,
            tx_start  => tx_start,
            tx_data   => tx_data,
            relay_ctl => RelayCtl,
            buzzer    => Buzzer,
            red_led   => RED_LED,
            green_led => GREEN_LED
        );

    uart_i: entity work.uart_tx_core
        port map (
            clk     => SysClk,
            data_in => tx_data,
            send    => tx_start,
            busy    => tx_busy,
            tx      => Tx
        );

    K2_ROW <= row_drive;
end Behavioral;
