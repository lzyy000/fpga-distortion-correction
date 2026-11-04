library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity project_reti_logiche is
    port (
    i_clk : in std_logic;
    i_rst : in std_logic;
    i_start : in std_logic;
    i_data : in std_logic_vector(7 downto 0);
    o_address : out std_logic_vector(15 downto 0);
    o_done : out std_logic;
    o_en : out std_logic;
    o_we : out std_logic;
    o_data : out std_logic_vector (7 downto 0)
    );
    end project_reti_logiche;

architecture Behavioral of project_reti_logiche is

type state is(
    WAIT_START,
    WAIT_MEM,
    READ_REQ_NCOL,
    READ_NCOL,
    READ_REQ_NRIG,
    READ_NRIG,
    READ_REQ_PIXEL_A0,
    READ_PIXEL_A0,
    SEARCH_MINMAX,
    CALC_DELTAVALUE,
    CALC_SHIFTLEVEL,
    READ_REQ_PIXEL_A1,
    READ_PIXEL_A1,
    CALC_NEWPIXEL,
    WRITE_NEWPIXEL,
    DONE,
    WAITING
);

signal state_curr : state;
signal state_next : state;
signal ncol : unsigned(7 downto 0);
signal nrig : unsigned(7 downto 0);
signal npixel : unsigned(15 downto 0);
signal pixel : unsigned(7 downto 0);
signal minpixel : unsigned(7 downto 0);
signal maxpixel : unsigned(7 downto 0);
signal addrRead : unsigned(15 downto 0);
signal addrWrite : unsigned(15 downto 0);
signal deltavalue : integer range 0 to 255;
signal shiftval : integer range 0 to 8;
signal tmpshiftval : integer range 0 to 8;

begin
    process(i_clk, i_rst, i_start, i_data)
    begin
        if (i_rst = '1')then
            state_next <= WAIT_START;
             
        elsif(i_clk'event and i_clk='1')then
                         
        case state_next is
            
            when WAIT_START =>
                if(i_start = '1')then
                    minpixel <= "11111111";
                    maxpixel <= "00000000";
                    addrRead <= "0000000000000010";
                    state_next <= READ_REQ_NCOL;
                else
                    state_next <= WAIT_START;
                end if;
                
            when WAIT_MEM =>
                if(state_curr = READ_REQ_NCOL)then
                    state_next <= READ_NCOL;
                elsif(state_curr = READ_REQ_NRIG)then
                    state_next <= READ_NRIG;
                elsif(state_curr = READ_REQ_PIXEL_A0)then
                    state_next <= READ_PIXEL_A0;
                elsif(state_curr = READ_REQ_PIXEL_A1)then
                    state_next <= READ_PIXEL_A1;
                elsif(state_curr = WRITE_NEWPIXEL)then
                    if(addrRead > npixel+1)then
                        state_next <= DONE;
                    else
                        addrRead <= addrRead +1;
                        addrWrite <= addrWrite +1;
                        state_next <= READ_REQ_PIXEL_A1;
                    end if;
                end if;

            when READ_REQ_NCOL =>   
                o_en <= '1';
                o_we <= '0';
                o_address <= "0000000000000000"; --Proviamo a usare le costanti per pulizia del codice
                state_curr <= READ_REQ_NCOL;
                state_next <= WAIT_MEM;
            
            when READ_NCOL =>       
                ncol <= unsigned(i_data); 
                state_next <= READ_REQ_NRIG;

            when READ_REQ_NRIG =>   
                o_en <= '1';
                o_we <= '0';
                o_address <= "0000000000000001";
                state_curr <= READ_REQ_NRIG;
                state_next <= WAIT_MEM;
            
            when READ_NRIG =>       
                nrig <= unsigned(i_data);
                npixel <= unsigned(i_data) * ncol;
                state_next <= READ_REQ_PIXEL_A0;

            when READ_REQ_PIXEL_A0 =>   
                o_en <= '1';
                o_we <= '0';
                o_address <= std_logic_vector(addrRead);
                state_curr <= READ_REQ_PIXEL_A0;
                state_next <= WAIT_MEM;
            
            when READ_PIXEL_A0 =>       
                pixel <= unsigned (i_data);
                state_next <= SEARCH_MINMAX;
            
            when SEARCH_MINMAX =>  
                if(pixel > maxpixel)then
                    maxpixel <= pixel;
                end if;
                if(pixel < minpixel)then
                    minpixel <= pixel;
                end if;
                if(addrRead = npixel+1)then
                    deltavalue <= TO_INTEGER(maxpixel - minpixel);
                    state_next <= CALC_DELTAVALUE;
                else
                    addrRead <= addrRead + 1;
                    state_next <= READ_REQ_PIXEL_A0;
                end if;

            when CALC_DELTAVALUE =>
               deltavalue <= TO_INTEGER(maxpixel - minpixel);
               state_next <= CALC_SHIFTLEVEL;
               
            when CALC_SHIFTLEVEL =>                
                if deltavalue= 0 then shiftval <= 8;
                elsif deltavalue <= 2 then shiftval <= 7;
                elsif deltavalue <= 6 then shiftval <= 6;
                elsif deltavalue <= 14 then shiftval <= 5;
                elsif deltavalue <= 30 then shiftval <= 4;
                elsif deltavalue <= 62 then shiftval <= 3;
                elsif deltavalue <= 126 then shiftval <= 2;
                elsif deltavalue <= 254 then shiftval <= 1;
                elsif deltavalue = 255 then shiftval <= 0;
                end if;
                addrRead <= "0000000000000010";
                addrWrite <= 2 + npixel; 
                state_next <= READ_REQ_PIXEL_A1;                  

            when READ_REQ_PIXEL_A1 =>   
                o_en <= '1';
                o_we <= '0';
                o_address <= std_logic_vector(addrRead);
                state_curr <= READ_REQ_PIXEL_A1;
                state_next <= WAIT_MEM;
            
            when READ_PIXEL_A1 =>       
                pixel <= unsigned (i_data) - minpixel;
                tmpshiftval <= shiftval;
                state_next <= CALC_NEWPIXEL;
            
            when CALC_NEWPIXEL =>       
                if(tmpshiftval > 0)then
                    if pixel < "10000000" then
                        pixel <= pixel(6 downto 0) & '0';
                        tmpshiftval <= tmpshiftval - 1;
                        state_next <= CALC_NEWPIXEL;
                    else
                        pixel <= "11111111";
                        state_next <= WRITE_NEWPIXEL;
                    end if;
                else
                    state_next <= WRITE_NEWPIXEL;
                end if;
                
            when WRITE_NEWPIXEL =>
                o_en <= '1';       
                o_we <= '1';
                o_data <= std_logic_vector(pixel);
                o_address <= std_logic_vector(addrWrite);
                state_curr <= WRITE_NEWPIXEL;
                state_next <= WAIT_MEM;
                
            when DONE =>       
                o_done <= '1';
                state_next <= WAITING;
            
            when WAITING =>  
                if(i_start = '0')then
                    state_next <= WAIT_START;
                    o_done <= '0';
                end if;
            
        end case;
        end if;
     end process;            
end Behavioral;