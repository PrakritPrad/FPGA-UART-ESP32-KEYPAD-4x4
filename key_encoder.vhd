library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity key_encoder is
	port (
		clk           : in  std_logic;
		frame_strobe  : in  std_logic;
		frame_key_valid : in  std_logic;
		frame_key_code  : in  std_logic_vector(3 downto 0);
		uart_busy     : in  std_logic;
		tx_start      : out std_logic;
		tx_data       : out std_logic_vector(7 downto 0)
	);
end key_encoder;

architecture Behavioral of key_encoder is
	signal key_held    : std_logic := '0';
	signal pending     : std_logic := '0';
	signal pending_data: std_logic_vector(7 downto 0) := (others => '0');
	signal tx_start_i  : std_logic := '0';
	signal tx_data_i   : std_logic_vector(7 downto 0) := (others => '0');

	function to_ascii(code : std_logic_vector(3 downto 0)) return std_logic_vector is
		variable key_num : integer;
		variable ascii_i : integer;
	begin
		key_num := to_integer(unsigned(code));
		case key_num is
			when 0  => ascii_i := character'pos('1');
			when 1  => ascii_i := character'pos('2');
			when 2  => ascii_i := character'pos('3');
			when 3  => ascii_i := character'pos('A');
			when 4  => ascii_i := character'pos('4');
			when 5  => ascii_i := character'pos('5');
			when 6  => ascii_i := character'pos('6');
			when 7  => ascii_i := character'pos('B');
			when 8  => ascii_i := character'pos('7');
			when 9  => ascii_i := character'pos('8');
			when 10 => ascii_i := character'pos('9');
			when 11 => ascii_i := character'pos('C');
			when 12 => ascii_i := character'pos('F');
			when 13 => ascii_i := character'pos('0');
			when 14 => ascii_i := character'pos('G');
			when others => ascii_i := character'pos('D');
		end case;
		return std_logic_vector(to_unsigned(ascii_i, 8));
	end function;
begin
	process(clk)
		variable ascii_now : std_logic_vector(7 downto 0);
	begin
		if rising_edge(clk) then
			-- Hold tx_start until UART raises busy so the request cannot be missed.
			if tx_start_i = '1' then
				if uart_busy = '1' then
					tx_start_i <= '0';
				end if;
			elsif (pending = '1') and (uart_busy = '0') then
				tx_data_i <= pending_data;
				tx_start_i <= '1';
				pending <= '0';
			end if;

			if frame_strobe = '1' then
				if frame_key_valid = '1' then
					if key_held = '0' then
						key_held <= '1';
						ascii_now := to_ascii(frame_key_code);
						if (uart_busy = '0') and (pending = '0') and (tx_start_i = '0') then
							tx_data_i <= ascii_now;
							tx_start_i <= '1';
						else
							pending <= '1';
							pending_data <= ascii_now;
						end if;
					end if;
				else
					key_held <= '0';
				end if;
			end if;
		end if;
	end process;

	tx_start <= tx_start_i;
	tx_data <= tx_data_i;
end Behavioral;

