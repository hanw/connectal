
// Copyright (c) 2014 Quanta Research Cambridge, Inc.

// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import FIFO::*;
import Vector::*;
import XbsvXilinxCells::*;
import XilinxCells::*;
import BviAurora::*;
import Clocks::*;
import FrequencyCounter::*;

(* always_enabled, always_ready *)
interface AuroraPins;
   method Action userClk(Bit#(1) p, Bit#(1) n);
   method Action mgtRefClk(Bit#(1) p, Bit#(1) n);
   method Action mgtRx(Bit#(1) p, Bit#(1) n);
   method Bit#(1) mgtTx_p();
   method Bit#(1) mgtTx_n();
   interface DiffPair smaUserClk;
endinterface

interface AuroraIndication;
    method Action received(Bit#(64) v);
    method Action debug(Bit#(1) channelUp, Bit#(1) laneUp, Bit#(1) hard_err, Bit#(1) soft_err, Bit#(1) qpllLock, Bit#(1) qpllRefClkLost);
    method Action userClkElapsedCycles(Bit#(32) cycles);
endinterface

interface AuroraRequest;
    method Action send(Bit#(64) v);
    method Action debug();
    method Action pma_init(Bit#(1) v);
    method Action userClkElapsedCycles(Bit#(32) period);
endinterface

interface Aurora;
   interface AuroraRequest request;
   interface AuroraPins pins;
endinterface

module mkAuroraRequest#(AuroraIndication indication)(Aurora);
   let defaultClock <- exposeCurrentClock;
   let defaultReset <- exposeCurrentReset;

   Wire#(Bit#(1)) userClkWireP <- mkDWire(0);
   Wire#(Bit#(1)) userClkWireN <- mkDWire(0);
   ReadOnly#(Bit#(1)) userClk <- mkIBUFDS(userClkWireP, userClkWireN);

   DiffPair smaUserClockDS <- mkOBUFDS(userClk);

   let userClkFreqCounter <- mkFrequencyCounter(defaultClock, defaultReset);

   Wire#(Bit#(1)) mgtRefClkWireP <- mkDWire(0);
   Wire#(Bit#(1)) mgtRefClkWireN <- mkDWire(0);
   Clock mgtRefClk <- mkClockIBUFDS_GTE2(True, mgtRefClkWireP, mgtRefClkWireN);

   let b2c <- mkB2C();
   Clock txClock <- mkClockBUFG(clocked_by b2c.c);

   Clock syncClock = txClock; // should be doubled

   let gtxe2Common <- mkGtxe2Common(defaultClock, mgtRefClk);

   let aur <- mkBviAurora64(/* init_clk */ defaultClock,
			    mgtRefClk,
			    /* sync_clk */ syncClock,
			    /* user_clk */ txClock,
			    /* init_clk_reset */ defaultReset,
			    /* refclk1_in_reset */ defaultReset,
			    /* reset */ defaultReset,
			    /* sync_clk_reset */ defaultReset,
			    /* user_clk_reset */ defaultReset);
      
   Reg#(Bit#(1)) pmaInitVal <- mkReg(0);
   Reg#(Bit#(15)) ccCounter <- mkReg(0);

   rule tx_out_clk_rule;
      b2c.inputclock(aur.tx.out_clk());
   endrule
   // gt_pll_lock

   rule settings;
      aur.loopback(1);
      aur.power.down(0);
      aur.pma.init(pmaInitVal);
   endrule
   rule qpll;
      aur.gt_qpllclk_quad2_in(gtxe2Common.qpllOutClk());
      aur.gt_qpllrefclk_quad2_in(gtxe2Common.qpllOutRefClk());
   endrule      

   rule receive if (unpack(aur.m_axi_rx.tvalid()));
      let v = 0;
      indication.received(aur.m_axi_rx.tdata());
   endrule

   // The CC block code should be sent atleast once for every 5000 clock cycles.
   rule doCC;
      let counter = ccCounter + 1;
      let doCC = 0;
      if (aur.channel.up() == 0)
	 counter = 0;
      if (counter > 4992)
	 doCC = 1;
      aur.do_.cc(doCC);
      if (counter > 5000)
	 counter = 0;
      ccCounter <= counter;
   endrule
   rule userclkfreqcounter_rule;
      let ec <- userClkFreqCounter.elapsedCycles();
      indication.userClkElapsedCycles(ec);
   endrule
	 
   interface AuroraRequest request;
       method Action send(Bit#(64) v) if (unpack(aur.s_axi_tx.tready()));
	  aur.s_axi_tx.tdata(v);
	  aur.s_axi_tx.tkeep(-1);
	  aur.s_axi_tx.tlast(1);
	  aur.s_axi_tx.tvalid(1);
       endmethod
      method Action debug();
	 indication.debug(aur.channel.up(), aur.lane.up(), aur.hard.err(), aur.soft.err(), gtxe2Common.qpllLock(), gtxe2Common.qpllRefClkLost());
      endmethod
      method Action pma_init(Bit#(1) v);
	 pmaInitVal <= v;
      endmethod
      method Action userClkElapsedCycles(Bit#(32) period);
	 userClkFreqCounter.start(period);
      endmethod
   endinterface
   interface AuroraPins pins;
       method Action userClk(Bit#(1) p, Bit#(1) n);
	  userClkWireP <= p;
	  userClkWireN <= n;
       endmethod
       method Action mgtRefClk(Bit#(1) p, Bit#(1) n);
	  mgtRefClkWireP <= p;
	  mgtRefClkWireN <= n;
       endmethod
       method Action mgtRx(Bit#(1) p, Bit#(1) n);
	  aur.rxp(p);
	  aur.rxn(n);
       endmethod
       method mgtTx_p = aur.txp;
       method mgtTx_n = aur.txn;

       interface DiffClock smaUserClk = smaUserClockDS;
   endinterface

endmodule