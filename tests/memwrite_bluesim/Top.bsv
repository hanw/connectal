// bsv libraries
import SpecialFIFOs::*;
import Vector::*;
import StmtFSM::*;
import FIFO::*;
import GetPut::*;
import ClientServer::*;
import Connectable::*;
import PCIE::*;

// portz libraries
import Leds::*;
import Directory::*;
import CtrlMux::*;
import Portal::*;
import ConnectalMemory::*;
import MemTypes::*;
import MemServer::*;
import MMU::*;
import HostInterface::*;
import MemSlaveEngine::*;

// generated by tool
import MemwriteRequestWrapper::*;
import DmaDebugRequestWrapper::*;
import MMUConfigRequestWrapper::*;
import MemwriteIndicationProxy::*;
import DmaDebugIndicationProxy::*;
import MMUConfigIndicationProxy::*;

// defined by user
import Memwrite::*;

typedef enum {HostDmaDebugIndication, HostDmaDebugRequest, HostMMUConfigRequest, HostMMUConfigIndication, MemwriteIndication, MemwriteRequest} IfcNames deriving (Eq,Bits);

module mkPortalTop(PortalTop#(PhysAddrWidth,DataBusWidth,Empty,1));

   MemwriteIndicationProxy memwriteIndicationProxy <- mkMemwriteIndicationProxy(MemwriteIndication);
   Memwrite memwrite <- mkMemwrite(memwriteIndicationProxy.ifc);
   MemwriteRequestWrapper memwriteRequestWrapper <- mkMemwriteRequestWrapper(MemwriteRequest,memwrite.request);

   Vector#(1, MemWriteClient#(DataBusWidth)) writeClients = cons(memwrite.dmaClient,nil);
   MMUConfigIndicationProxy hostMMUConfigIndicationProxy <- mkMMUConfigIndicationProxy(HostMMUConfigIndication);
   MMU#(PhysAddrWidth) hostMMU <- mkMMU(0, True, hostMMUConfigIndicationProxy.ifc);
   MMUConfigRequestWrapper hostMMUConfigRequestWrapper <- mkMMUConfigRequestWrapper(HostMMUConfigRequest, hostMMU.request);

   DmaDebugIndicationProxy hostDmaDebugIndicationProxy <- mkDmaDebugIndicationProxy(HostDmaDebugIndication);
   MemServer#(PhysAddrWidth,DataBusWidth,1) dma <- mkMemServerW(hostDmaDebugIndicationProxy.ifc, writeClients, cons(hostMMU,nil));
   DmaDebugRequestWrapper hostDmaDebugRequestWrapper <- mkDmaDebugRequestWrapper(HostDmaDebugRequest, dma.request);

   MemMaster#(PhysAddrWidth,DataBusWidth) dma1 = (interface MemMaster;
	  interface PhysMemReadClient read_client;
	     interface Get readReq;
		method ActionValue#(PhysMemRequest#(PhysAddrWidth)) get() if (False);
		   return ?;
	        endmethod
	     endinterface
	  endinterface
	  interface PhysMemWriteClient write_client;
	     interface Get writeReq;
		method ActionValue#(PhysMemRequest#(PhysAddrWidth)) get() if (False);
		   return ?;
	        endmethod
	     endinterface
	  endinterface
      endinterface);

   Reg#(Bit#(32)) cycles <- mkReg(0);
   Reg#(Bit#(32)) reqCycles <- mkReg(0);
   Reg#(Bit#(32)) dataCycles <- mkReg(0);
   rule count;
      cycles <= cycles + 1;
   endrule

   rule startdump if (cycles == 1);
      $dumpvars();
   endrule

   rule finish if (reqCycles == 10000);
      $dumpoff();
   endrule

   MemSlaveEngine#(DataBusWidth) memSlaveEngine <- mkMemSlaveEngine(PciId {bus: 4, dev: 2, func: 0});
   mkConnection(dma.masters[0], memSlaveEngine.slave);

   rule displayTlp;
      let tlp <- memSlaveEngine.tlp.request.get();
      TLPMemory4DWHeader hdr4dw = unpack(tlp.data);
      TLPMemoryIO3DWHeader hdr3dw = unpack(tlp.data);
      let newReqCycles = reqCycles;
      if (tlp.sof && hdr4dw.format == MEM_WRITE_4DW_DATA) begin
	 $display("%d 4dw req %h %d", cycles-reqCycles, hdr4dw.addr<<2, fromInteger(valueOf(DataBusWidth)));
	 newReqCycles = cycles;
      end
      else if (tlp.sof && hdr3dw.format == MEM_WRITE_3DW_DATA) begin
	 $display("%d 3dw req %h %d", cycles-reqCycles, hdr4dw.addr<<2, fromInteger(valueOf(DataBusWidth)));
	 newReqCycles = cycles;
      end
      else if (tlp.sof) begin
	 $display("%d sof %h", cycles-reqCycles, tlp.data);
	 newReqCycles = cycles;
      end
      else begin
	 $display("%d data %h", cycles-reqCycles, tlp.data);
	 dataCycles <= cycles;
	 newReqCycles = cycles;
      end
      reqCycles <= newReqCycles;
   endrule

   Vector#(6,StdPortal) portals;
   portals[0] = memwriteRequestWrapper.portalIfc;
   portals[1] = memwriteIndicationProxy.portalIfc; 
   portals[2] = hostDmaDebugRequestWrapper.portalIfc;
   portals[3] = hostDmaDebugIndicationProxy.portalIfc; 
   portals[4] = hostMMUConfigRequestWrapper.portalIfc;
   portals[5] = hostMMUConfigIndicationProxy.portalIfc;

   
   StdDirectory dir <- mkStdDirectory(portals);
   let ctrl_mux <- mkSlaveMux(dir,portals);
   
   interface interrupt = getInterruptVector(portals);
   interface slave = ctrl_mux;
   interface masters = cons(dma1,nil);
   interface leds = default_leds;
endmodule
