library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity pin_lock_fsm is
	Port (
		clk       : in  std_logic;
		key_valid : in  std_logic;
		key_code  : in  std_logic_vector(3 downto 0);
		uart_busy : in  std_logic;
		tx_start  : out std_logic;
		tx_data   : out std_logic_vector(7 downto 0);
		relay_ctl : out std_logic;
		buzzer    : out std_logic;
		red_led   : out std_logic;
		green_led : out std_logic
	);
end pin_lock_fsm;

architecture Behavioral of pin_lock_fsm is
	type state_t is (LOCKED, UNLOCKED, VERIFY_OLD_FOR_CHANGE, SET_NEW_PIN, LOCKOUT);
	type pin_array_t is array (0 to 3) of integer range 0 to 9;

	constant CLK_HZ          : integer := 20000000;
	constant LOCKOUT_SECONDS : integer := 10;
	constant LOCKOUT_CYCLES  : integer := CLK_HZ * LOCKOUT_SECONDS;
	constant BUZZ_SHORT      : integer := 1000000; -- 50 ms
	constant BUZZ_LONG       : integer := 8000000; -- 400 ms
	constant BUZZ_GAP        : integer := 400000;  -- 20 ms
	constant FAIL_LED_CYCLES : integer := 10000000; -- 500 ms
	constant KEY_GUARD_CYCLES: integer := 120000; -- ~6 ms @ 20 MHz
	constant RELEASE_CONFIRM_CYCLES: integer := 50000; -- ~2.5 ms @ 20 MHz

	signal state             : state_t := LOCKED;
	signal key_held          : std_logic := '0';
	signal key_released      : std_logic := '1';
	signal key_guard_timer   : integer range 0 to KEY_GUARD_CYCLES := 0;
	signal release_timer     : integer range 0 to RELEASE_CONFIRM_CYCLES := 0;
	signal entry_count       : integer range 0 to 4 := 0;
	signal fail_count        : integer range 0 to 5 := 0;
	signal lockout_timer     : integer range 0 to LOCKOUT_CYCLES := 0;

	signal pin_ref           : pin_array_t := (1, 2, 3, 4);
	signal pin_buf           : pin_array_t := (0, 0, 0, 0);

	signal tx_start_i        : std_logic := '0';
	signal tx_data_i         : std_logic_vector(7 downto 0) := (others => '0');
	signal event_pending     : std_logic := '0';
	signal event_data        : std_logic_vector(7 downto 0) := (others => '0');

	signal relay_i           : std_logic := '0';
	signal buzz_timer        : integer range 0 to BUZZ_LONG := 0;
	signal buzz_gap_timer    : integer range 0 to BUZZ_GAP := 0;
	signal buzz_double_next  : std_logic := '0';
	signal fail_led_timer    : integer range 0 to FAIL_LED_CYCLES := 0;

	function buffer_matches_pin(
		buf : pin_array_t;
		ref : pin_array_t
	) return boolean is
	begin
		return (buf(0) = ref(0)) and
			   (buf(1) = ref(1)) and
			   (buf(2) = ref(2)) and
			   (buf(3) = ref(3));
	end function;

begin
	process(clk)
		variable key_num      : integer;
		variable new_key_evt  : std_logic;
		variable is_digit     : std_logic;
		variable digit_value  : integer range 0 to 9;
		variable is_f_key     : std_logic;
		variable is_g_key     : std_logic;
		variable is_a_key     : std_logic;
		variable do_fail      : std_logic;
		variable do_lockout   : std_logic;
		variable do_send_u    : std_logic;
		variable do_send_k    : std_logic;
		variable do_send_l    : std_logic;
		variable do_send_o    : std_logic;
		variable do_send_g    : std_logic;
		variable do_send_n    : std_logic;
		variable do_send_a    : std_logic;
		variable do_send_c    : std_logic;
		variable do_send_digit: std_logic;
		variable digit_ascii  : std_logic_vector(7 downto 0);
	begin
		if rising_edge(clk) then
			new_key_evt := '0';
			is_digit := '0';
			digit_value := 0;
			is_f_key := '0';
			is_g_key := '0';
			is_a_key := '0';
			do_fail := '0';
			do_lockout := '0';
			do_send_u := '0';
			do_send_k := '0';
			do_send_l := '0';
			do_send_o := '0';
			do_send_g := '0';
			do_send_n := '0';
			do_send_a := '0';
			do_send_c := '0';
			do_send_digit := '0';
			digit_ascii := (others => '0');

			if key_guard_timer > 0 then
				key_guard_timer <= key_guard_timer - 1;
			end if;

			if fail_led_timer > 0 then
				fail_led_timer <= fail_led_timer - 1;
			end if;

			-- Release detection: confirm button was released for stable period
			if key_valid = '0' then
				-- Button appears released, start confirmation timer
				if release_timer > 0 then
					release_timer <= release_timer - 1;
				elsif key_released = '0' then
					-- Timer expired and button still released
					key_released <= '1';
				end if;
			else
				-- Button is still pressed, restart release timer if needed
				if key_released = '0' then
					release_timer <= RELEASE_CONFIRM_CYCLES;
				end if;
			end if;

			-- UART send handshake (hold until uart_busy acknowledges).
			if tx_start_i = '1' then
				if uart_busy = '1' then
					tx_start_i <= '0';
				end if;
			elsif (event_pending = '1') and (uart_busy = '0') then
				tx_data_i <= event_data;
				tx_start_i <= '1';
				event_pending <= '0';
			end if;

			-- Buzzer timing engine.
			if buzz_timer > 0 then
				buzz_timer <= buzz_timer - 1;
			elsif buzz_gap_timer > 0 then
				buzz_gap_timer <= buzz_gap_timer - 1;
			elsif buzz_double_next = '1' then
				buzz_timer <= BUZZ_SHORT;
				buzz_double_next <= '0';
			end if;

			-- Edge detect key event from scanner level signal.
			-- Only trigger if: button not currently held AND button is physically released AND we see a press
			if (key_held = '0') and (key_released = '1') and (key_valid = '1') then
				-- Detect new key press
				key_held <= '1';
				key_released <= '0';
				release_timer <= RELEASE_CONFIRM_CYCLES;
				key_guard_timer <= KEY_GUARD_CYCLES;
				new_key_evt := '1';
				key_num := to_integer(unsigned(key_code));

				case key_num is
					when 0  => is_digit := '1'; digit_value := 1;
					when 1  => is_digit := '1'; digit_value := 2;
					when 2  => is_digit := '1'; digit_value := 3;
					when 4  => is_digit := '1'; digit_value := 4;
					when 5  => is_digit := '1'; digit_value := 5;
					when 6  => is_digit := '1'; digit_value := 6;
					when 8  => is_digit := '1'; digit_value := 7;
					when 9  => is_digit := '1'; digit_value := 8;
					when 10 => is_digit := '1'; digit_value := 9;
					when 13 => is_digit := '1'; digit_value := 0;
					when 12 => is_f_key := '1'; -- F
					when 14 => is_g_key := '1'; -- G
					when 3  => is_a_key := '1'; -- A (backspace)
					when others => null;
				end case;
			elsif (key_held = '1') and (key_valid = '0') then
				-- Button released (detected when key_valid goes low)
				key_held <= '0';
			end if;

			if state = LOCKOUT then
				if lockout_timer > 0 then
					lockout_timer <= lockout_timer - 1;
				else
					state <= LOCKED;
					fail_count <= 0;
					entry_count <= 0;
					relay_i <= '0';
				end if;
			elsif new_key_evt = '1' then
				case state is
					when LOCKED =>
						if is_digit = '1' then
							if entry_count < 4 then
								pin_buf(entry_count) <= digit_value;
								entry_count <= entry_count + 1;
								do_send_digit := '1';
								digit_ascii := std_logic_vector(to_unsigned(character'pos('0') + digit_value, 8));
							end if;
						elsif is_a_key = '1' then
							if entry_count > 0 then
								entry_count <= entry_count - 1;
								pin_buf(entry_count - 1) <= 0;
								do_send_a := '1';
							end if;
						elsif is_f_key = '1' then
							if (entry_count = 4) and buffer_matches_pin(pin_buf, pin_ref) then
								state <= UNLOCKED;
								relay_i <= '1';
								fail_count <= 0;
								entry_count <= 0;
								do_send_u := '1';
								buzz_timer <= BUZZ_SHORT;
								buzz_gap_timer <= 0;
								buzz_double_next <= '0';
							else
								do_fail := '1';
								entry_count <= 0;
								do_send_c := '1';
							end if;
						end if;

					when UNLOCKED =>
						if is_f_key = '1' then
							state <= LOCKED;
							relay_i <= '0';
							entry_count <= 0;
							do_send_k := '1';
							buzz_timer <= BUZZ_SHORT;
							buzz_gap_timer <= 0;
							buzz_double_next <= '0';
						elsif is_g_key = '1' then
							state <= VERIFY_OLD_FOR_CHANGE;
							entry_count <= 0;
							pin_buf <= (0, 0, 0, 0);
							do_send_g := '1';
						end if;

					when VERIFY_OLD_FOR_CHANGE =>
						if is_digit = '1' then
							if entry_count < 4 then
								pin_buf(entry_count) <= digit_value;
								entry_count <= entry_count + 1;
								do_send_digit := '1';
								digit_ascii := std_logic_vector(to_unsigned(character'pos('0') + digit_value, 8));
							end if;
						elsif is_a_key = '1' then
							if entry_count > 0 then
								entry_count <= entry_count - 1;
								pin_buf(entry_count - 1) <= 0;
								do_send_a := '1';
							end if;
						elsif is_f_key = '1' then
							if (entry_count = 4) and buffer_matches_pin(pin_buf, pin_ref) then
								state <= SET_NEW_PIN;
								entry_count <= 0;
								pin_buf <= (0, 0, 0, 0);
								fail_count <= 0;
								do_send_n := '1';
							else
								do_fail := '1';
								state <= UNLOCKED;
								entry_count <= 0;
								do_send_c := '1';
							end if;
						elsif is_g_key = '1' then
							state <= UNLOCKED;
							entry_count <= 0;
							pin_buf <= (0, 0, 0, 0);
							do_send_c := '1';
						end if;

					when SET_NEW_PIN =>
						if is_digit = '1' then
							if entry_count < 4 then
								pin_buf(entry_count) <= digit_value;
								entry_count <= entry_count + 1;
								do_send_digit := '1';
								digit_ascii := std_logic_vector(to_unsigned(character'pos('0') + digit_value, 8));
							end if;
						elsif is_a_key = '1' then
							if entry_count > 0 then
								entry_count <= entry_count - 1;
								pin_buf(entry_count - 1) <= 0;
								do_send_a := '1';
							end if;
						elsif is_f_key = '1' then
							if entry_count = 4 then
								pin_ref(0) <= pin_buf(0);
								pin_ref(1) <= pin_buf(1);
								pin_ref(2) <= pin_buf(2);
								pin_ref(3) <= pin_buf(3);
								state <= UNLOCKED;
								entry_count <= 0;
								pin_buf <= (0, 0, 0, 0);
								fail_count <= 0;
							else
								do_fail := '1';
								state <= UNLOCKED;
								entry_count <= 0;
								do_send_c := '1';
							end if;
						elsif is_g_key = '1' then
							state <= UNLOCKED;
							entry_count <= 0;
							pin_buf <= (0, 0, 0, 0);
							do_send_c := '1';
						end if;

					when others =>
						null;
				end case;
			end if;

			if do_fail = '1' then
				do_send_o := '1';
				fail_led_timer <= FAIL_LED_CYCLES;
				buzz_timer <= BUZZ_SHORT;
				buzz_gap_timer <= BUZZ_GAP;
				buzz_double_next <= '1';
				if fail_count = 4 then
					do_lockout := '1';
					fail_count <= 5;
				else
					fail_count <= fail_count + 1;
				end if;
			end if;

			if do_lockout = '1' then
				state <= LOCKOUT;
				relay_i <= '0';
				lockout_timer <= LOCKOUT_CYCLES;
				do_send_l := '1';
				buzz_timer <= BUZZ_LONG;
				buzz_gap_timer <= 0;
				buzz_double_next <= '0';
			end if;

			if do_send_u = '1' then
				if (tx_start_i = '0') and (event_pending = '0') and (uart_busy = '0') then
					tx_data_i <= x"55"; -- U
					tx_start_i <= '1';
				else
					event_data <= x"55";
					event_pending <= '1';
				end if;
			elsif do_send_k = '1' then
				if (tx_start_i = '0') and (event_pending = '0') and (uart_busy = '0') then
					tx_data_i <= x"4B"; -- K
					tx_start_i <= '1';
				else
					event_data <= x"4B";
					event_pending <= '1';
				end if;
			elsif do_send_l = '1' then
				if (tx_start_i = '0') and (event_pending = '0') and (uart_busy = '0') then
					tx_data_i <= x"4C"; -- L
					tx_start_i <= '1';
				else
					event_data <= x"4C";
					event_pending <= '1';
				end if;
			elsif do_send_o = '1' then
				if (tx_start_i = '0') and (event_pending = '0') and (uart_busy = '0') then
					tx_data_i <= x"4F"; -- O
					tx_start_i <= '1';
				else
					event_data <= x"4F";
					event_pending <= '1';
				end if;
			elsif do_send_n = '1' then
				if (tx_start_i = '0') and (event_pending = '0') and (uart_busy = '0') then
					tx_data_i <= x"4E"; -- N
					tx_start_i <= '1';
				else
					event_data <= x"4E";
					event_pending <= '1';
				end if;
			elsif do_send_g = '1' then
				if (tx_start_i = '0') and (event_pending = '0') and (uart_busy = '0') then
					tx_data_i <= x"47"; -- G
					tx_start_i <= '1';
				else
					event_data <= x"47";
					event_pending <= '1';
				end if;
			elsif do_send_a = '1' then
				if (tx_start_i = '0') and (event_pending = '0') and (uart_busy = '0') then
					tx_data_i <= x"41"; -- A
					tx_start_i <= '1';
				else
					event_data <= x"41";
					event_pending <= '1';
				end if;
			elsif do_send_c = '1' then
				if (tx_start_i = '0') and (event_pending = '0') and (uart_busy = '0') then
					tx_data_i <= x"43"; -- C
					tx_start_i <= '1';
				else
					event_data <= x"43";
					event_pending <= '1';
				end if;
			elsif do_send_digit = '1' then
				if (tx_start_i = '0') and (event_pending = '0') and (uart_busy = '0') then
					tx_data_i <= digit_ascii;
					tx_start_i <= '1';
				elsif event_pending = '0' then
					event_data <= digit_ascii;
					event_pending <= '1';
				end if;
			end if;
		end if;
	end process;

	tx_start <= tx_start_i;
	tx_data <= tx_data_i;
	relay_ctl <= not relay_i;
	buzzer <= '1' when (buzz_timer > 0) else '0';

	red_led <= '1' when
		(state = LOCKED) or
		(state = LOCKOUT) or
		(state = VERIFY_OLD_FOR_CHANGE) or
		(state = SET_NEW_PIN) or
		(fail_led_timer > 0)
	else '0';

	green_led <= '1' when
		(state = UNLOCKED) or
		(state = VERIFY_OLD_FOR_CHANGE) or
		(state = SET_NEW_PIN)
	else '0';

end Behavioral;

