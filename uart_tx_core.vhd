library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_tx_core is
    port (
        clk     : in  std_logic;
        data_in : in  std_logic_vector(7 downto 0);
        send    : in  std_logic;
        busy    : out std_logic;
        tx      : out std_logic
    );
end uart_tx_core;

architecture rtl of uart_tx_core is
    constant BAUD_DIV : integer := 2083;

    signal clk_count : integer range 0 to BAUD_DIV-1 := 0;
    signal bit_index : integer range 0 to 9 := 0;
    signal tx_reg    : std_logic := '1';
    signal shift_reg : std_logic_vector(7 downto 0) := (others => '0');
    signal sending   : std_logic := '0';
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if sending = '0' then
                if send = '1' then
                    sending <= '1';
                    clk_count <= 0;
                    bit_index <= 0;
                    shift_reg <= data_in;
                    tx_reg <= '0';
                else
                    tx_reg <= '1';
                end if;
            else
                if clk_count = BAUD_DIV-1 then
                    clk_count <= 0;

                    case bit_index is
                        when 0 =>
                            tx_reg <= shift_reg(0);
                            bit_index <= 1;
                        when 1 =>
                            tx_reg <= shift_reg(1);
                            bit_index <= 2;
                        when 2 =>
                            tx_reg <= shift_reg(2);
                            bit_index <= 3;
                        when 3 =>
                            tx_reg <= shift_reg(3);
                            bit_index <= 4;
                        when 4 =>
                            tx_reg <= shift_reg(4);
                            bit_index <= 5;
                        when 5 =>
                            tx_reg <= shift_reg(5);
                            bit_index <= 6;
                        when 6 =>
                            tx_reg <= shift_reg(6);
                            bit_index <= 7;
                        when 7 =>
                            tx_reg <= shift_reg(7);
                            bit_index <= 8;
                        when 8 =>
                            tx_reg <= '1';
                            bit_index <= 9;
                        when others =>
                            tx_reg <= '1';
                            bit_index <= 0;
                            sending <= '0';
                    end case;
                else
                    clk_count <= clk_count + 1;
                end if;
            end if;
        end if;
    end process;

    tx <= tx_reg;
    busy <= sending;
end rtl;
