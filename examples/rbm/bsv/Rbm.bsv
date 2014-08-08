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

import Vector::*;
import FIFO::*;
import FIFOF::*;
import DefaultValue::*;
import GetPut::*;
import ClientServer::*;
import Connectable::*;
import FloatingPoint::*;
import BRAM::*;

import PortalMemory::*;
import MemTypes::*;
import DmaVector::*;
import AxiMasterSlave::*;
import HostInterface::*;
import MemreadEngine::*;
import MemwriteEngine::*;

import Sigmoid::*;
import FloatOps::*;
import Pipe::*;
import RbmTypes::*;
import DotProdServer::*;


function Float tokenValue(MmToken v) = v.v;

interface StatesPipe#(numeric type n, numeric type dmasz);
   method Action start(Bit#(32) readPointer, Bit#(32) readOffset,
		       Bit#(32) readPointer2, Bit#(32) readOffset2,
		       Bit#(32) writePointer, Bit#(32) writeOffset, Bit#(32) numElts);
   method ActionValue#(Bool) finish();
endinterface

module  mkStatesPipe#(Vector#(2,Server#(MemengineCmd,Bool)) readServers,
		      Vector#(2, PipeOut#(Bit#(TMul#(N,32)))) readPipes,
		      Vector#(1,Server#(MemengineCmd,Bool)) writeServers,
		      Vector#(1, PipeIn#(Bit#(TMul#(N,32))))  writePipes)(StatesPipe#(N, DmaSz))
   provisos (Bits#(Vector#(N, Float), DmaSz));
   Vector#(2, VectorSource#(DmaSz, Vector#(N,Float))) statesources <- mapM(uncurry(mkMemreadVectorSource), zip(readServers, readPipes));
   PipeOut#(Vector#(N, Float)) dmaStatesPipe <- mkComputeStatesPipe2(statesources[0].pipe, statesources[1].pipe);
   VectorSink#(DmaSz, Vector#(N, Float)) dmaStatesSink <- mkMemwriteVectorSink(writeServers[0], writePipes[0]);

   method Action start(Bit#(32) readPointer, Bit#(32) readOffset,
		       Bit#(32) readPointer2, Bit#(32) readOffset2,
		       Bit#(32) writePointer, Bit#(32) writeOffset, Bit#(32) numElts);
      statesources[0].start(readPointer, extend(readOffset), extend(unpack(numElts)));
      statesources[1].start(readPointer2, extend(readOffset2), extend(unpack(numElts)));
      dmaStatesSink.start(writePointer, extend(writeOffset), extend(unpack(numElts)));
   endmethod
   method ActionValue#(Bool) finish();
      let b <- dmaStatesSink.finish();
      return b;
   endmethod
endmodule

interface UpdateWeights#(numeric type n, numeric type dmasz);
   method Action start(Bit#(32) posAssociationsPointer, Bit#(32) negAssociationsPointer, 
		       Bit#(32) weightsPointer, Bit#(32) numElts, Float learningRateOverNumExamples);
   method ActionValue#(Bool) finish();
endinterface

module  mkUpdateWeights#(Vector#(3,Server#(MemengineCmd,Bool)) readServers,
			    Vector#(3, PipeOut#(Bit#(TMul#(N,32)))) readPipes,
			    Vector#(1,Server#(MemengineCmd,Bool)) writeServers,
			    Vector#(1, PipeIn#(Bit#(TMul#(N,32))))  writePipes)(UpdateWeights#(N, DmaSz))
   provisos (Bits#(Vector#(N, Float), DmaSz));

   Vector#(3, VectorSource#(DmaSz, Vector#(N,Float))) sources <- mapM(uncurry(mkMemreadVectorSource), zip(readServers, readPipes));

   let n = valueOf(N);

   Reg#(Float) learningRateOverNumExamples <- mkReg(defaultValue);

   FIFOF#(Vector#(N,Float)) wfifo <- mkFIFOF();
   Vector#(N, FloatAlu) adders <- replicateM(mkFloatAdder(defaultValue));
   Vector#(N, FloatAlu) adders2 <- replicateM(mkFloatAdder(defaultValue));
   Vector#(N, FloatAlu) multipliers <- replicateM(mkFloatMultiplier(defaultValue));
   VectorSink#(DmaSz, Vector#(N, Float)) sink <- mkMemwriteVectorSink(writeServers[0], writePipes[0]);

// weights += learningRate * (pos_associations - neg_associations) / num_examples;
   rule sub;
      let pa = sources[0].pipe.first();
      sources[0].pipe.deq();
      let na = sources[1].pipe.first();
      sources[1].pipe.deq();
      for (Integer i = 0; i < n; i = i+1) begin
	 adders[i].request.put(tuple2(pa[i], -na[i]));
      end
   endrule
   rule mul;
      for (Integer i = 0; i < n; i = i+1) begin
	 let sumexc <- adders[i].response.get();
	 multipliers[i].request.put(tuple2(learningRateOverNumExamples, tpl_1(sumexc)));
      end
   endrule
   rule add;
      let weights = sources[2].pipe.first();
      sources[2].pipe.deq();
      for (Integer i = 0; i < n; i = i+1) begin
	 let resultexc <- multipliers[i].response.get();
	 adders2[i].request.put(tuple2(weights[i], tpl_1(resultexc)));
      end
   endrule
   rule result;
      Vector#(N, Float) r;
      for (Integer i = 0; i < n; i = i+1) begin
	 let resultexc <- adders2[i].response.get();
	 r[i] = tpl_1(resultexc);
      end
      wfifo.enq(r);
   endrule

   for (Integer i = 0; i < 3; i = i + 1)
      rule finishSources;
	 let b <- sources[i].finish();
      endrule

   method Action start(Bit#(32) posAssociationsPointer, Bit#(32) negAssociationsPointer, Bit#(32) weightsPointer, Bit#(32) numElts, Float lrone);
      learningRateOverNumExamples <= lrone;
      sources[0].start(posAssociationsPointer, 0, extend(numElts));
      sources[1].start(negAssociationsPointer, 0, extend(numElts));
      sources[2].start(weightsPointer, 0, extend(numElts));
      sink.start(weightsPointer, 0, extend(numElts));
   endmethod
   method ActionValue#(Bool) finish();
      let b <- sink.finish();
      return b;
   endmethod
endmodule
   
interface SumOfErrorSquared#(numeric type n, numeric type dmasz);
   interface PipeOut#(Float) pipe;
   method Action start(Bit#(32) dataPointer, Bit#(32) predPointer, Bit#(32) numElts);
endinterface

module  mkSumOfErrorSquared#(Vector#(2,Server#(MemengineCmd,Bool)) readServers,
			     Vector#(2, PipeOut#(Bit#(TMul#(N,32)))) readPipes)(SumOfErrorSquared#(N, DmaSz))
   provisos (Bits#(Vector#(N, Float), DmaSz));
   
   Vector#(2, VectorSource#(DmaSz, Vector#(N,Float))) sources <- mapM(uncurry(mkMemreadVectorSource), zip(readServers, readPipes));
   let n = valueOf(N);
   let dotprod <- mkSharedInterleavedDotProdServer(0);

   FirstLastPipe#(Bit#(ObjectOffsetSize)) firstlastPipe <- mkFirstLastPipe();
   PipeOut#(Float) aPipe <- mkFunnel1(sources[0].pipe);
   PipeOut#(Float) bPipe <- mkFunnel1(sources[1].pipe);
   let joinPipe <- mkJoin(tuple2, aPipe, bPipe);
   let subPipe <- mkFloatSubPipe(joinPipe);
   rule fromsub;
      match {.first, .last} <- toGet(firstlastPipe.pipe).get();
      let diff <- toGet(subPipe).get();
      MmToken t = MmToken { v: diff, first: first, last: last };
      dotprod.aInput.put(t);
      dotprod.bInput.put(t);
   endrule

   for (Integer i = 0; i < 2; i = i + 1)
      rule finishSources;
	 let b <- sources[i].finish();
      endrule

   interface PipeOut pipe = mapPipe(tokenValue, dotprod.pipes[0]);
   method Action start(Bit#(32) dataPointer, Bit#(32) predPointer, Bit#(32) numElts);
      sources[0].start(dataPointer, 0, extend(numElts));
      sources[1].start(predPointer, 0, extend(numElts));
      firstlastPipe.start(extend(numElts));
   endmethod
endmodule: mkSumOfErrorSquared

interface Rbm#(numeric type n);
   interface RbmRequest rbmRequest;
   interface SigmoidRequest sigmoidRequest;
   interface ObjectReadClient#(TMul#(32,n)) readClient;
   interface ObjectWriteClient#(TMul#(32,n)) writeClient;
endinterface

module  mkRbm#(HostType host, RbmIndication rbmInd, SigmoidIndication sigmoidInd)(Rbm#(N))
   provisos (Add#(1,a__,N),
	     Add#(N,0,n),
	     Mul#(N,32,DmaSz));

   let n = valueOf(n);
   
   // TODO: figure out the correct amount of buffering required
   MemreadEngineV#(TMul#(n,32), 2, 9) readEngine  <- mkMemreadEngine; 
   MemwriteEngineV#(TMul#(n,32),2, 3) writeEngine <- mkMemwriteEngine; 
   
   let res = readEngine.readServers;
   let rep = readEngine.dataPipes;
   let wes = writeEngine.writeServers;
   let wep = writeEngine.dataPipes;
   
   SigmoidIfc#(TMul#(32,n)) sigmoid <- mkSigmoid(sigmoidInd, takeAt(0,res), takeAt(0,rep), takeAt(0,wes), takeAt(0,wep)); // 2 read, 1 write
   StatesPipe#(N, DmaSz) states <- mkStatesPipe(takeAt(2,res), takeAt(2,rep), takeAt(1,wes), takeAt(1,wep));              // 2 read, 1 write
   UpdateWeights#(N, DmaSz) updateWeights <- mkUpdateWeights(takeAt(4,res), takeAt(4,rep), takeAt(2,wes), takeAt(2,wep)); // 3 read, 1 write
   SumOfErrorSquared#(N, DmaSz) sumOfErrorSquared <- mkSumOfErrorSquared(takeAt(7,res), takeAt(7,rep));                   // 2 read, 0 write

   rule statesDone;
      $display("statesDone");
      let b <- states.finish();
      rbmInd.statesDone();
   endrule

   rule updateWeightsDone;
      $display("updateWeightsDone");
      let b <- updateWeights.finish();
      rbmInd.updateWeightsDone();
   endrule

   rule sumOfErrorSquaredDone;
      $display("sumOfErrorSquaredDone");
      sumOfErrorSquared.pipe.deq();
      rbmInd.sumOfErrorSquared(pack(sumOfErrorSquared.pipe.first()));
   endrule

   interface SigmoidRequest sigmoidRequest = sigmoid.sigmoidRequest;
   interface RbmRequest rbmRequest;
      method Action dbg();
      endmethod

      method Action finish();
	 $finish(0);
      endmethod
      method Action computeStates(Bit#(32) readPointer, Bit#(32) readOffset,
				  Bit#(32) readPointer2, Bit#(32) readOffset2,
				  Bit#(32) writePointer, Bit#(32) writeOffset, Bit#(32) numElts);
	 states.start(readPointer, readOffset,
		      readPointer2, readOffset2,
		      writePointer,writeOffset, numElts);
      endmethod
      method Action updateWeights(Bit#(32) posAssociationsPointer,
	 Bit#(32) negAssociationsPointer,
				  Bit#(32) weightsPointer,
				  Bit#(32) numElts,
				  Bit#(32) learningRateOverNumExamples);
	 updateWeights.start(posAssociationsPointer, negAssociationsPointer, 
			     weightsPointer, numElts, 
			     unpack(learningRateOverNumExamples));
      endmethod
      method Action sumOfErrorSquared(Bit#(32) dataPointer, Bit#(32) predPointer, Bit#(32) numElts);
	 sumOfErrorSquared.start(dataPointer, predPointer, numElts);
      endmethod
   endinterface   
   interface Vector readClient = readEngine.dmaClient;
   interface Vector writeClient = writeEngine.dmaClient;

endmodule