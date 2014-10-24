// bsv libraries
import Vector::*;
import FIFO::*;
import Connectable::*;

// portz libraries
import Portal::*;
import Directory::*;
import CtrlMux::*;
import Portal::*;
import Leds::*;
import MemTypes::*;
import Bscan::*;


// generated by tool
import BscanIndicationProxy::*;
import BscanRequestWrapper::*;

// defined by user
import BscanRequest::*;

typedef enum {BscanIndication, BscanRequest} IfcNames deriving (Eq,Bits);

module mkConnectalTop#(BscanTop bscan)(StdConnectalTop#(PhysAddrWidth));

   // instantiate user portals
   BscanIndicationProxy bscanIndicationProxy <- mkBscanIndicationProxy(BscanIndication);
   BscanRequest bscanRequest <- mkBscanRequest(bscanIndicationProxy.ifc, bscan);
   BscanRequestWrapper bscanRequestWrapper <- mkBscanRequestWrapper(BscanRequest,bscanRequest);
   
   Vector#(2,StdPortal) portals;
   portals[0] = bscanIndicationProxy.portalIfc;
   portals[1] = bscanRequestWrapper.portalIfc; 
   
   // instantiate system directory
   StdDirectory dir <- mkStdDirectory(portals);
   let ctrl_mux <- mkSlaveMux(dir,portals);
   
   interface interrupt = getInterruptVector(portals);
   interface slave = ctrl_mux;
   interface masters = nil;

endmodule : mkConnectalTop
