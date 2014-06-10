
// Copyright (c) 2012 Nokia, Inc.
// Copyright (c) 2013 Quanta Research Cambridge, Inc.

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
import FIFOF::*;
import BRAMFIFO::*;
import Vector::*;
import Clocks::*;
import GetPut::*;
import ClientServer::*;
import PCIE::*;
import GetPutWithClocks::*;
import Connectable::*;
import PortalMemory::*;
import MemTypes::*;
import DmaUtils::*;
import ClientServer::*;
import AxiMasterSlave::*;
import MemreadEngine::*;
import HDMI::*;
import XADC::*;
import YUV::*;
import Gearbox::*;
import MIMO::*;
import BlueScope::*;

interface HdmiDisplayRequest;
   method Action startFrameBuffer(Int#(32) base, UInt#(32) rows, UInt#(32) cols, UInt#(32) pixels);
   method Action stopFrameBuffer();
   method Action getTransferStats();
   method Action setTraceTransfers(Bit#(1) trace);
endinterface
interface HdmiDisplayIndication;
   method Action transferStarted(Bit#(32) count);
   method Action transferFinished(Bit#(32) count);
   method Action transferStats(Bit#(32) count, Bit#(32) transferCycles, Bit#(64) sumOfCycles);
endinterface

interface HdmiDisplay;
`ifdef HDMI_BLUESCOPE
   interface BlueScopeRequest  bluescopeRequest;
   interface ObjectWriteClient#(64) bluescopeWriteClient;
`endif
    interface HdmiDisplayRequest displayRequest;
    interface HdmiInternalRequest internalRequest;
    interface ObjectReadClient#(64) dmaClient;
    interface HDMI#(Bit#(HdmiBits)) hdmi;
    interface XADC xadc;
endinterface

module mkHdmiDisplay#(Clock hdmi_clock,
		      HdmiDisplayIndication hdmiDisplayIndication,
		      HdmiInternalIndication hdmiInternalIndication
`ifdef HDMI_BLUESCOPE
		      , BlueScopeIndication bluescopeIndication
`endif
)(HdmiDisplay);
    Clock defaultClock <- exposeCurrentClock;
    Reset defaultReset <- exposeCurrentReset;
    Reset hdmi_reset <- mkAsyncReset(2, defaultReset, hdmi_clock);

   Reg#(UInt#(16)) rowsReg <- mkReg(1080);
   Reg#(UInt#(16)) colsReg <- mkReg(1920);
   Reg#(UInt#(24)) pixelCountReg <- mkReg(1080*1920);

    Reg#(Bool) sendVsyncIndication <- mkReg(False);
    SyncPulseIfc vsyncPulse <- mkSyncHandshake(hdmi_clock, hdmi_reset, defaultClock);
    Reg#(Bit#(1)) bozobit <- mkReg(0, clocked_by hdmi_clock, reset_by hdmi_reset);

    Reg#(Maybe#(Bit#(32))) referenceReg <- mkReg(tagged Invalid);
    FIFO#(Bit#(64)) mrFifo <- mkSizedBRAMFIFO(1024);
    MemreadEngine#(64,16) memreadEngine <- mkMemreadEngine;

    HdmiGenerator#(Rgb888) hdmiGen <- mkHdmiGenerator(defaultClock, defaultReset,
							vsyncPulse, hdmiInternalIndication, clocked_by hdmi_clock, reset_by hdmi_reset);
`ifndef ZC706
   Rgb888ToYyuv converter <- mkRgb888ToYyuv(clocked_by hdmi_clock, reset_by hdmi_reset);
   mkConnection(hdmiGen.rgb888, converter.rgb888);
   HDMI#(Bit#(HdmiBits)) hdmisignals <- mkHDMI(converter.yyuv, clocked_by hdmi_clock, reset_by hdmi_reset);
`else
   HDMI#(Bit#(HdmiBits)) hdmisignals <- mkHDMI(hdmiGen.rgb888, clocked_by hdmi_clock, reset_by hdmi_reset);
`endif   
`ifdef HDMI_BLUESCOPE
   let bluescope <- mkSyncBlueScope(65536, bluescopeIndication, hdmi_clock, hdmi_reset, defaultClock, defaultReset);
   MIMO#(1, 16, 64, Bit#(4)) mimo <- mkMIMO(MIMOConfiguration { unguarded: False, bram_based: False }, clocked_by hdmi_clock, reset_by hdmi_reset);
   Reg#(Bool) triggered <- mkReg(False, clocked_by hdmi_clock, reset_by hdmi_reset);
   rule toGearbox if ((hdmisignals.hdmi_vsync == 1) || triggered);
      Bit#(4) v = 0;
      v[0] = hdmisignals.hdmi_vsync;
      v[1] = hdmisignals.hdmi_de;
      v[2] = hdmisignals.hdmi_hsync;
      v[3] = hdmisignals.hdmi_vsync;
      triggered <= True;
      if (mimo.enqReadyN(1))
	 mimo.enq(1, cons(v,nil));
      else
	 $display("mimo.stalled mimo.count=%d", mimo.count);
   endrule
   rule gearboxToBlueScope if (mimo.deqReadyN(16));
      Bit#(64) v = pack(mimo.first());
      mimo.deq(16);
      bluescope.dataIn(v, v);
   endrule
`endif

   SyncFIFOIfc#(Bit#(64)) synchronizer <- mkSyncFIFO(32, defaultClock, defaultReset, hdmi_clock);
   rule fromMemread;
      let v <- toGet(memreadEngine.dataPipes[0]).get;
      mrFifo.enq(v);
   endrule
   rule toSynch;
      let v <- toGet(mrFifo).get();
      synchronizer.enq(v);
   endrule
   Reg#(Bit#(1)) evenOdd <- mkReg(0, clocked_by hdmi_clock, reset_by hdmi_reset);
   Reg#(Vector#(2,Bit#(32))) doublePixelReg <- mkReg(unpack(0), clocked_by hdmi_clock, reset_by hdmi_reset);
   rule doPut;
      Vector#(2,Bit#(32)) doublePixel = doublePixelReg;
      let pixel = doublePixel[evenOdd];
      if (evenOdd == 0) begin
	 doublePixel = unpack(synchronizer.first);
	 synchronizer.deq;
	 pixel = doublePixel[0];
      end
      doublePixelReg <= doublePixel;
      evenOdd <= evenOdd + 1;
      hdmiGen.request.put(pixel);
   endrule      

   Reg#(Bit#(32)) transferCount <- mkReg(0);
   Reg#(Bit#(32)) transferCyclesSnapshot <- mkReg(0);
   Reg#(Bit#(32)) transferCycles <- mkReg(0);
   Reg#(Bit#(48)) transferSumOfCycles<- mkReg(0);
   Reg#(Bit#(32)) vsyncCount <- mkReg(0);

   FIFOF#(Bool) vsyncFifo <- mkFIFOF();
   rule vsyncrule if (vsyncPulse.pulse());
      vsyncCount <= vsyncCount + 1;
      if (vsyncFifo.notFull())
	 vsyncFifo.enq(True);
   endrule

   Reg#(Bool) traceTransfers <- mkReg(False);
   rule notransfer if (referenceReg matches tagged Invalid);
      vsyncFifo.deq();
   endrule
   rule startTransfer if (referenceReg matches tagged Valid .reference);
      memreadEngine.readServers[0].request.put(MemengineCmd{pointer:reference, base:0, len:pack(extend(pixelCountReg))*4, burstLen:64});
      if (traceTransfers)
	 hdmiDisplayIndication.transferStarted(transferCount);
      transferCyclesSnapshot <= transferCycles;
      vsyncFifo.deq();
   endrule
   rule countCycles;
      transferCycles <= transferCycles + 1;
   endrule
   rule finishTransferRule;
      let b <- memreadEngine.readServers[0].response.get;
      transferCount <= transferCount + 1;
      let tc = transferCycles - transferCyclesSnapshot;
      transferSumOfCycles <= transferSumOfCycles + extend(tc);
      if (traceTransfers)
	 hdmiDisplayIndication.transferFinished(transferCount);
   endrule

    rule bozobit_rule;
        bozobit <= ~bozobit;
    endrule

    interface HdmiDisplayRequest displayRequest;
	method Action startFrameBuffer(Int#(32) base, UInt#(32) rows, UInt#(32) cols, UInt#(32) pixels);
	   rowsReg <= truncate(rows);
	   colsReg <= truncate(cols);
	   pixelCountReg <= truncate(pixels);
	   $display("startFrameBuffer %h", base);
           referenceReg <= tagged Valid truncate(pack(base));
	   hdmiGen.control.setTestPattern(0);
	endmethod
       method Action stopFrameBuffer();
	  referenceReg <= tagged Invalid;
	  hdmiGen.control.setTestPattern(1);
       endmethod
       method Action getTransferStats();
          hdmiDisplayIndication.transferStats(transferCount, transferCycles-transferCyclesSnapshot, extend(transferSumOfCycles));
       endmethod
       method Action setTraceTransfers(Bit#(1) trace);
	  traceTransfers <= unpack(trace);
       endmethod
    endinterface: displayRequest

    interface ObjectReadClient dmaClient = memreadEngine.dmaClient;
    interface HDMI hdmi = hdmisignals;
    interface HdmiInternalRequest internalRequest = hdmiGen.control;
`ifdef HDMI_BLUESCOPE
    interface BlueScopeRequest bluescopeRequest = bluescope.requestIfc;
    interface ObjectWriteClient bluescopeWriteClient = bluescope.writeClient;
`endif
    interface XADC xadc;
        method Bit#(4) gpio;
            return { bozobit, hdmisignals.hdmi_vsync,
                hdmisignals.hdmi_data[8], hdmisignals.hdmi_data[0]};
                //hdmiGen.hdmi.hsync, hdmi_de};
        endmethod
    endinterface: xadc
endmodule
