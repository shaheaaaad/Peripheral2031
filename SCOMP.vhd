-- SCOMP, the Simple Computer.
-- This VHDL defines a simple 16-bit processor that is easy to understand and modify.
-- Updated 2023-10-24

library ieee;
library altera_mf;
library lpm;

use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;
use altera_mf.altera_mf_components.all;
use lpm.lpm_components.all;


entity SCOMP is
	port(
		clock     : in    std_logic;
		resetn    : in    std_logic;
		IRQ       : in    std_logic_vector(3 downto 0);
		IO_WRITE  : out   std_logic;
		IO_CYCLE  : out   std_logic;
		IO_ADDR   : out   std_logic_vector(10 downto 0);
		IO_DATA   : inout std_logic_vector(15 downto 0);
		dbg_FETCH : out   std_logic;
		dbg_AC    : out   std_logic_vector(15 downto 0);
		dbg_PC    : out   std_logic_vector(10 downto 0);
		dbg_MA    : out   std_logic_vector(10 downto 0);
		dbg_MD    : out   std_logic_vector(15 downto 0);
		dbg_IR    : out   std_logic_vector(15 downto 0)
	);
end SCOMP;

architecture a of SCOMP is
	type state_type is (
		init, fetch, decode, ex_nop,
		ex_load, ex_store, ex_store2, ex_iload, ex_istore, ex_istore2, ex_loadi,
		ex_add, ex_addi, ex_sub,
		ex_jump, ex_jneg, ex_jzero, ex_jpos,
		ex_call, ex_return, ex_reti,
		ex_and, ex_or, ex_xor, ex_shift,
		ex_in, ex_in2, ex_out, ex_out2
	);

	type stack_type is array (0 to 15) of std_logic_vector(10 downto 0);

	signal state         : state_type;
	signal PC_stack      : stack_type;
	signal AC            : std_logic_vector(15 downto 0);
	signal AC_shifted    : std_logic_vector(15 downto 0);
	signal IR            : std_logic_vector(15 downto 0);
	signal mem_data      : std_logic_vector(15 downto 0);
	signal PC            : std_logic_vector(10 downto 0);
	signal next_mem_addr : std_logic_vector(10 downto 0);
	signal operand       : std_logic_vector(10 downto 0);
	signal MW            : std_logic;
	signal IO_WRITE_int  : std_logic;

	signal GIE           : std_logic;                     -- global interrupt enable
	signal IIE           : std_logic_vector( 3 downto 0); -- interrupt enable mask
	signal int_req       : std_logic_vector( 3 downto 0); -- interrupt request
	signal int_req_sync  : std_logic_vector( 3 downto 0); -- registered version of INT_REQ
	signal int_ack       : std_logic_vector( 3 downto 0); -- interrupt acknowledge
	signal PC_saved      : std_logic_vector(10 downto 0); -- saced PC while inside ISR
	signal AC_saved      : std_logic_vector(15 downto 0); -- saced AC while inside ISR
	

begin
	-- use altsyncram component for unified program and data memory
	altsyncram_component : altsyncram
	GENERIC MAP (
		numwords_a => 2048,
		widthad_a => 11,
		width_a => 16,
		init_file => "NewLEDsTest.mif",
		clock_enable_input_a => "BYPASS",
		clock_enable_output_a => "BYPASS",
		intended_device_family => "MAX 10",
		lpm_hint => "ENABLE_RUNTIME_MOD=NO",
		lpm_type => "altsyncram",
		operation_mode => "SINGLE_PORT",
		outdata_aclr_a => "NONE",
		outdata_reg_a => "UNREGISTERED",
		power_up_uninitialized => "FALSE",
		read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ",
		width_byteena_a => 1
	)
	PORT MAP (
		wren_a    => MW,
		clock0    => clock,
		address_a => next_mem_addr,
		data_a    => AC,
		q_a       => mem_data
	);

	-- use lpm function to shift AC
	shifter: lpm_clshift
	generic map (
		lpm_width     => 16,
		lpm_widthdist => 4,
		lpm_shifttype => "arithmetic"
	)
	port map (
		data      => AC,
		distance  => IR(3 downto 0),
		direction => IR(4),
		result    => AC_shifted
	);

	-- Memory address comes from PC during fetch, otherwise from operand
	with state select next_mem_addr <=
		PC when fetch,
		operand when others;

	-- This makes the operand available immediately after fetch, and also
	-- handles indirect addressing of iload and istore
	with state select operand <=
		mem_data(10 downto 0) when decode,
		mem_data(10 downto 0) when ex_iload,
		mem_data(10 downto 0) when ex_istore2,
		IR(10 downto 0) when others;

	-- use lpm function to drive i/o bus
	io_bus: lpm_bustri
	generic map (
		lpm_width => 16
	)
	port map (
		data     => AC,
		enabledt => IO_WRITE_int,
		tridata  => IO_DATA
	);

	IO_ADDR  <= IR(10 downto 0);
	IO_WRITE <= IO_WRITE_int;

	process (clock, resetn)
	begin
		if (resetn = '0') then          -- Active-low asynchronous reset
			state <= init;
		elsif (rising_edge(clock)) then
			case state is
				when init =>
					MW        <= '0';           -- clear memory write flag
					PC        <= "00000000000"; -- reset PC to the beginning of memory, address 0x000
					AC        <= x"0000";       -- clear AC register
					IO_WRITE_int <= '0';        -- don't drive IO
					IO_CYCLE  <= '0';           -- stop any active IO operations
					state     <= fetch;         -- start fetch-decode-execute cycle
					GIE       <= '1';           -- Not currently in ISR
					IIE       <= "0000";        -- Disable all interrupts
					int_ack   <= "1111";        -- Clear any pending interrupts
					int_req_sync <= "0000";     -- 

				when fetch =>
					IO_WRITE_int <= '0';   -- lower IO_WRITE after an out
					IO_CYCLE  <= '0';      -- lower IO_CYCLE after an in
					-- Interrupt Control
					if (GIE = '1') AND  -- If Global Interrupt Enable set and...
					  (int_req_sync /= "0000") then -- ...an interrupt is pending
						if int_req_sync(0) = '1' then   -- Got interrupt on IRQ0
							int_ack <= "0001";     -- Acknowledge the interrupt
							PC <= "00000000001";    -- Redirect execution
						elsif int_req_sync(1) = '1' then
							int_ack <= "0010";     -- repeat for other pins
							PC <= "00000000010";
						elsif int_req_sync(2) = '1' then
							int_ack <= "0100";
							PC <= "00000000011";
						elsif int_req_sync(3) = '1' then
							int_ack <= "1000";
							PC <= "00000000100";
						end if;
						GIE <= '0';            -- Disable interrupts while in ISR
						AC_saved <= AC;        -- Save AC
						PC_saved <= PC;        -- Save PC
						state <= fetch;        -- Repeat FETCH with new PC
					ELSE -- either no interrupt or interrupts disabled
						PC        <= PC + 1;   -- increment PC to next instruction address
						state     <= decode;
						int_ack   <= "0000";   -- Clear any interrupt acknowledge
					END IF;

				when decode =>
					IR    <= mem_data;          -- latch instruction into the IR
					case mem_data(15 downto 11) is -- opcode is top 5 bits of instruction
						when "00000" =>       -- no operation (nop)
							state <= ex_nop;
						when "00001" =>       -- load
							state <= ex_load;
						when "00010" =>       -- store
							state <= ex_store;
						when "00011" =>       -- add
							state <= ex_add;
						when "00100" =>       -- sub
							state <= ex_sub;
						when "00101" =>       -- jump
							state <= ex_jump;
						when "00111" =>       -- jneg
							state <= ex_jpos;
						when "00110" =>       -- jpos
							state <= ex_jneg;
						when "01000" =>       -- jzero
							state <= ex_jzero;
						when "01001" =>       -- and
							state <= ex_and;
						when "01010" =>       -- or
							state <= ex_or;
						when "01011" =>       -- xor
							state <= ex_xor;
						when "01100" =>       -- shift
							state <= ex_shift;
						when "01101" =>       -- addi
							state <= ex_addi;
						when "01110" =>       -- iload
							state <= ex_iload;
						when "01111" =>       -- istore
							state <= ex_istore;
						when "10000" =>       -- call
							state <= ex_call;
						when "10001" =>       -- return
							state <= ex_return;
						when "10010" =>       -- in
							state <= ex_in;
						when "10011" =>       -- out
							state <= ex_out;
							IO_WRITE_int <= '1'; -- raise IO_WRITE
						when "10100" =>       -- cli
							IIE <= IIE and not(operand(3 DOWNTO 0));  -- disable indicated interrupts
							state <= fetch;
						when "10101" =>       -- sei
							IIE <= IIE or operand(3 DOWNTO 0);  -- enable indicated interrupts
							state <= fetch;
						when "10110" =>       -- reti
							state <= ex_reti;
						when "10111" =>       -- loadi
							state <= ex_loadi;
						when others =>
							state <= ex_nop;   -- invalid opcodes default to nop
					end case;

				when ex_nop =>
					state <= fetch;

				when ex_load =>
					AC    <= mem_data;        -- latch data from mem_data (memory contents) to AC
					state <= fetch;

				when ex_store =>
					MW    <= '1';             -- drop MW to end write cycle
					state <= ex_store2;

				when ex_store2 =>
					MW    <= '0';             -- drop MW to end write cycle
					state <= fetch;

				when ex_add =>
					AC    <= AC + mem_data;   -- addition
					state <= fetch;

				when ex_sub =>
					AC    <= AC - mem_data;   -- addition
					state <= fetch;

				when ex_jump =>
					PC    <= operand; -- overwrite PC with new address
					state <= fetch;

				when ex_jpos =>
					if (AC(15) = '0')  and  (AC /= "0000000000000000") then
						PC    <= operand;      -- Change the program counter to the operand
					end if;
					state <= fetch;

				when ex_jneg =>
					if (AC(15) = '1') then
						PC    <= operand;      -- Change the program counter to the operand
					end if;
					state <= fetch;

				when ex_jzero =>
					if (AC = x"0000") then
						PC    <= operand;
					end if;
					state <= fetch;

				when ex_and =>
					AC    <= AC and mem_data;   -- logical bitwise AND
					state <= fetch;

				when ex_or =>
					AC    <= AC or mem_data;
					state <= fetch;

				when ex_xor =>
					AC    <= AC xor mem_data;
					state <= fetch;

				when ex_shift =>
					AC    <= AC_shifted;
					state <= fetch;

				when ex_addi =>
					-- sign extension
					AC    <= AC + (operand(10) & operand(10) & operand(10) &
					 operand(10) & operand(10) & operand(10 downto 0));
					state <= fetch;

				when ex_iload =>
					-- indirect addressing is handled in next_mem_addr assignment.
					state       <= ex_load;

				when ex_istore =>
					MW          <= '1';
					state       <= ex_istore2;

				when ex_istore2 =>
					MW          <= '0';
					state       <= fetch;

				when ex_call =>
					for i in 0 to 8 loop
						PC_stack(i + 1) <= PC_stack(i);
					end loop;
					PC_stack(0) <= PC;
					PC          <= operand;
					state       <= fetch;

				when ex_return =>
					for i in 0 to 8 loop
						PC_stack(i) <= PC_stack(i + 1);
					end loop;
					PC          <= PC_stack(0);
					state       <= fetch;

				WHEN ex_reti =>
					GIE   <= '1';      -- re-enable interrupts
					PC    <= PC_saved; -- restore saved registers
					AC    <= AC_saved;
					state <= fetch;

				when ex_in =>
					IO_CYCLE <= '1';
					state <= ex_in2;

				when ex_in2 =>
					AC <= IO_DATA;
					IO_CYCLE <= '0';
					state <= fetch;

				when ex_out =>
					IO_CYCLE <= '1';
					state <= ex_out2;

				when ex_out2 =>
					IO_CYCLE <= '0';
					state <= fetch;

				when ex_loadi =>
					AC    <= (operand(10) & operand(10) & operand(10) &
					 operand(10) & operand(10) & operand(10 downto 0));
					state <= fetch;

				when others =>
					state <= init;          -- if an invalid state is reached, reset
					
			end case;
			
			int_req_sync <= int_req;  -- register async interrupt requests to SCOMP's clock
			
		end if;
	end process;

	dbg_FETCH <= '1' when state = fetch else '0';
	dbg_AC  <= AC;
	dbg_PC  <= PC;
	dbg_MA  <= next_mem_addr;
	dbg_MD  <= mem_data;
	dbg_IR  <= IR;

	-- This process monitors the external interrupt pins, setting
	-- some flags if a rising edge is detected, and clearing flags
	-- once the interrupt is acknowledged.
	process(resetn, IRQ, int_ack, IIE)
	begin
		if (resetn = '0') then
			int_req <= "0000";  -- clear all interrupts on reset
		else
			for i in 0 to 3 loop -- for each of the 4 interrupt pins
				if (int_ack(i) = '1') or (IIE(i) = '0') then
					int_req(i) <= '0';   -- if acknowledged or masked, clear interrupt
				elsif rising_edge(IRQ(i)) then
					int_req(i) <= '1';   -- if rising edge on IRQ, request interrupt
				end if;
			end loop;
		end if;
	end process;


end a;
