library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity debouncer is
	generic (
		STABLE_CYCLES : integer := 400000
	);
	port (
		clk       : in  std_logic;
		noisy_in  : in  std_logic;
		clean_out : out std_logic
	);
end debouncer;

architecture Behavioral of debouncer is
	signal stable_state : std_logic := '1';
	signal sample_prev  : std_logic := '1';
	signal cnt          : integer range 0 to STABLE_CYCLES-1 := 0;
begin
	process(clk)
	begin
		if rising_edge(clk) then
			if noisy_in /= sample_prev then
				sample_prev <= noisy_in;
				cnt <= 0;
			elsif noisy_in /= stable_state then
				if cnt = STABLE_CYCLES-1 then
					stable_state <= noisy_in;
					cnt <= 0;
				else
					cnt <= cnt + 1;
				end if;
			else
				cnt <= 0;
			end if;
		end if;
	end process;

	clean_out <= stable_state;
end Behavioral;

