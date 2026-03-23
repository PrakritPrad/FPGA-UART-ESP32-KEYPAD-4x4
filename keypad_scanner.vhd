library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity keypad_scanner is
	generic (
		ROW_HOLD_CYCLES : integer := 5000
	);
	port (
		clk          : in  std_logic;
		col_in       : in  std_logic_vector(3 downto 0);
		row_out      : out std_logic_vector(3 downto 0);
		frame_strobe : out std_logic;
		key_valid    : out std_logic;
		key_code     : out std_logic_vector(3 downto 0)
	);
end keypad_scanner;

architecture Behavioral of keypad_scanner is
	signal row_idx         : integer range 0 to 3 := 0;
	signal row_timer       : integer range 0 to ROW_HOLD_CYCLES-1 := 0;
	signal scan_found      : std_logic := '0';
	signal scan_code       : std_logic_vector(3 downto 0) := (others => '0');
	signal frame_strobe_i  : std_logic := '0';
	signal key_valid_i     : std_logic := '0';
	signal key_code_i      : std_logic_vector(3 downto 0) := (others => '0');
begin
	process(clk)
		variable found_now : std_logic;
		variable code_now  : std_logic_vector(3 downto 0);
	begin
		if rising_edge(clk) then
			frame_strobe_i <= '0';

			if row_timer = ROW_HOLD_CYCLES-1 then
				row_timer <= 0;

				found_now := '0';
				code_now  := (others => '0');

				if col_in(0) = '0' then
					found_now := '1';
					code_now := std_logic_vector(to_unsigned((row_idx * 4), 4));
				elsif col_in(1) = '0' then
					found_now := '1';
					code_now := std_logic_vector(to_unsigned((row_idx * 4) + 1, 4));
				elsif col_in(2) = '0' then
					found_now := '1';
					code_now := std_logic_vector(to_unsigned((row_idx * 4) + 2, 4));
				elsif col_in(3) = '0' then
					found_now := '1';
					code_now := std_logic_vector(to_unsigned((row_idx * 4) + 3, 4));
				end if;

				if (scan_found = '0') and (found_now = '1') then
					scan_found <= '1';
					scan_code <= code_now;
				end if;

				if row_idx = 3 then
					frame_strobe_i <= '1';
					if scan_found = '1' then
						key_valid_i <= '1';
						key_code_i <= scan_code;
					elsif found_now = '1' then
						key_valid_i <= '1';
						key_code_i <= code_now;
					else
						key_valid_i <= '0';
					end if;

					scan_found <= '0';
					scan_code <= (others => '0');
					row_idx <= 0;
				else
					row_idx <= row_idx + 1;
				end if;
			else
				row_timer <= row_timer + 1;
			end if;
		end if;
	end process;

	with row_idx select
		row_out <= "1110" when 0,
				   "1101" when 1,
				   "1011" when 2,
				   "0111" when 3,
				   "1111" when others;

	frame_strobe <= frame_strobe_i;
	key_valid <= key_valid_i;
	key_code <= key_code_i;
end Behavioral;

