##
## Copyright (C) 2012-2013 Nokia, Inc
## Copyright (c) 2013-2014 Quanta Research Cambridge, Inc.

## Permission is hereby granted, free of charge, to any person
## obtaining a copy of this software and associated documentation
## files (the "Software"), to deal in the Software without
## restriction, including without limitation the rights to use, copy,
## modify, merge, publish, distribute, sublicense, and/or sell copies
## of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:

## The above copyright notice and this permission notice shall be
## included in all copies or substantial portions of the Software.

## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
## EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
## MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
## NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
## BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
## ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
## CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
## SOFTWARE.

##
import os
import math
import re
import md5

import globalv
import AST
import string
import util

preambleTemplate='''
import FIFO::*;
import FIFOF::*;
import GetPut::*;
import Connectable::*;
import Clocks::*;
import FloatingPoint::*;
import Adapter::*;
import Leds::*;
import Vector::*;
import SpecialFIFOs::*;
import ConnectalMemory::*;
import Portal::*;
import MemPortal::*;
import MemTypes::*;
import Pipe::*;
%(extraImports)s

'''

requestStructTemplate='''
typedef struct {
%(paramStructDeclarations)s
} %(MethodName)s_Request deriving (Bits);
'''

requestOutputPipeInterfaceTemplate='''\
    interface PipeOut#(%(MethodName)s_Request) %(methodName)s_PipeOut;
'''

exposedProxyInterfaceTemplate='''
%(responseElements)s
// exposed proxy interface
interface %(Dut)sPortal;
    interface PipePortal#(0, %(indicationChannelCount)s, 32) portalIfc;
    interface %(Package)s::%(Ifc)s ifc;
endinterface
interface %(Dut)s;
    interface StdPortal portalIfc;
    interface %(Package)s::%(Ifc)s ifc;
endinterface

(* synthesize *)
module %(moduleContext)s mk%(Dut)sPortalSynth#(Bit#(32) id) (%(Dut)sPortal);
    Vector#(0, PipeIn#(Bit#(32))) requestPipes = nil;
    Vector#(%(channelCount)s, PipeOut#(Bit#(32))) indicationPipes = newVector();
%(indicationMethodRules)s
    interface %(Package)s::%(Ifc)s ifc;
%(indicationMethods)s
    endinterface
%(portalIfc)s
endmodule

// exposed proxy implementation
module %(moduleContext)s mk%(Dut)sPortal#(idType id) (%(Dut)sPortal)
    provisos (Bits#(idType, __a),
              Add#(a__, __a, 32));
    let rv <- mk%(Dut)sPortalSynth(extend(pack(id)));
    return rv;
endmodule

// synthesizeable proxy MemPortal
(* synthesize *)
module mk%(Dut)sSynth#(Bit#(32) id)(%(Dut)s);
  let dut <- mk%(Dut)sPortal(id);
  let memPortal <- mkMemPortal(id, dut.portalIfc);
  interface MemPortal portalIfc = memPortal;
  interface %(Package)s::%(Ifc)s ifc = dut.ifc;
endmodule

// exposed proxy MemPortal
module mk%(Dut)s#(idType id)(%(Dut)s)
   provisos (Bits#(idType, a__),
	     Add#(b__, a__, 32));
   let rv <- mk%(Dut)sSynth(extend(pack(id)));
   return rv;
endmodule
'''

exposedWrapperInterfaceTemplate='''
%(requestElements)s
// exposed wrapper portal interface
interface %(Dut)sPipes;
    interface Vector#(%(requestChannelCount)s, PipeIn#(Bit#(32))) inputPipes;
%(requestOutputPipeInterfaces)s
endinterface
interface %(Dut)sPortal;
    interface PipePortal#(%(requestChannelCount)s, 0, 32) portalIfc;
endinterface
// exposed wrapper MemPortal interface
interface %(Dut)s;
    interface StdPortal portalIfc;
endinterface

instance Connectable#(%(Dut)sPipes,%(Ifc)s);
   module mkConnection#(%(Dut)sPipes pipes, %(Ifc)s ifc)(Empty);
%(mkConnectionMethodRules)s
   endmodule
endinstance

// exposed wrapper Portal implementation
(* synthesize *)
module mk%(Dut)sPipes#(Bit#(32) id)(%(Dut)sPipes);
    Vector#(%(requestChannelCount)s, PipeIn#(Bit#(32))) requestPipeIn = newVector();
    Vector#(0, PipeOut#(Bit#(32))) indicationPipes = nil;
%(methodRules)s
    interface Vector inputPipes = requestPipeIn;
%(outputPipes)s
endmodule

module mk%(Dut)sPortal#(idType id, %(Ifc)s ifc)(%(Dut)sPortal)
    provisos (Bits#(idType, __a),
              Add#(a__, __a, 32));
    let pipes <- mk%(Dut)sPipes(zeroExtend(pack(id)));
    mkConnection(pipes, ifc);
    let requestPipes = pipes.inputPipes;
    Vector#(0, PipeOut#(Bit#(32))) indicationPipes = nil;
%(portalIfc)s
endmodule

interface %(Dut)sMemPortalPipes;
    interface %(Dut)sPipes pipes;
    interface MemPortal#(16,32) portalIfc;
endinterface

(* synthesize *)
module mk%(Dut)sMemPortalPipes#(Bit#(32) id)(%(Dut)sMemPortalPipes);

  let p <- mk%(Dut)sPipes(zeroExtend(pack(id)));

  PipePortal#(%(requestChannelCount)s, 0, 32) portalifc = (interface PipePortal;
        interface Vector requests = p.inputPipes;
        interface Vector indications = nil;
    endinterface);

  let memPortal <- mkMemPortal(id, portalifc);
  interface %(Dut)sPipes pipes = p;
  interface MemPortal portalIfc = memPortal;
endmodule

// exposed wrapper MemPortal implementation
module mk%(Dut)s#(idType id, %(Ifc)s ifc)(%(Dut)s)
   provisos (Bits#(idType, a__),
	     Add#(b__, a__, 32));
  let dut <- mk%(Dut)sMemPortalPipes(zeroExtend(pack(id)));
  mkConnection(dut.pipes, ifc);
  interface MemPortal portalIfc = dut.portalIfc;
endmodule
'''

responseStructTemplate='''
typedef struct {
%(paramStructDeclarations)s
} %(MethodName)s_Response deriving (Bits);
'''

portalIfcTemplate='''
    interface PipePortal portalIfc;
        interface Vector requests = requestPipes;
        interface Vector indications = indicationPipes;
    endinterface
'''

requestRuleTemplate='''
    FromBit#(32,%(MethodName)s_Request) %(methodName)s_requestFifo <- mkFromBit();
    requestPipeIn[%(channelNumber)s] = toPipeIn(%(methodName)s_requestFifo);
'''

mkConnectionMethodTemplate='''
    rule handle_%(methodName)s_request;
        let request <- toGet(pipes.%(methodName)s_PipeOut).get();
        ifc.%(methodName)s(%(paramsForCall)s);
    endrule
'''

indicationRuleTemplate='''
    ToBit#(32,%(MethodName)s_Response) %(methodName)s_responseFifo <- mkToBit();
    indicationPipes[%(channelNumber)s] = toPipeOut(%(methodName)s_responseFifo);
'''

indicationMethodDeclTemplate='''
    method Action %(methodName)s(%(formals)s);'''

indicationMethodTemplate='''
    method Action %(methodName)s(%(formals)s);
        %(methodName)s_responseFifo.enq(%(MethodName)s_Response {%(structElements)s});
        //$display(\"indicationMethod \'%(methodName)s\' invoked\");
    endmethod'''

def toBsvType(self):
    if len(self.params):
        return '%s#(%s)' % (self.name, ','.join([str(toBsvType(p)) for p in self.params]))
    else:
        return self.name

def methsubsts(self, outerTypeName):
    sub = { 'dut': util.decapitalize(outerTypeName),
          'Dut': util.capitalize(outerTypeName),
          'methodName': self.name,
          'MethodName': util.capitalize(self.name),
          'channelNumber': self.channelNumber,
          'ord': self.channelNumber,
          'methodReturnType': self.return_type.name}
    paramStructDeclarations = ['    %s %s;' % (toBsvType(p.type), p.name) for p in self.params]
    if not self.params:
        paramStructDeclarations = ['    %s %s;' % ('Bit#(32)', 'padding')]
    sub['paramStructDeclarations'] = '\n'.join(paramStructDeclarations)
    sub['paramType'] = ', '.join(['%s' % toBsvType(p.type) for p in self.params])
    sub['formals'] = ', '.join(['%s %s' % (toBsvType(p.type), p.name) for p in self.params])
    structElements = ['%s: %s' % (p.name, p.name) for p in self.params]
    if not self.params:
        structElements = ['padding: 0']
    sub['structElements'] = ', '.join(structElements)
    return sub

def collectRequestElement(self, substs):
    return requestStructTemplate % substs

def collectResponseElement(self, substs):
    return responseStructTemplate % substs

def collectMethodRule(self, substs):
    return requestRuleTemplate % substs

def collectIndicationMethodRule(self, substs):
    return indicationRuleTemplate % substs

def collectIndicationMethod(self, substs):
    return indicationMethodTemplate % substs

def substsTemplate(self,name):
    methodAction = []
    for m in self.decls:
        if m.type == 'Method':
            newitem = {'name': m.name, 'channelNumber': m.channelNumber, 'methodReturnType': m.return_type.name}
            newitem['params'] = [{'name': p.name, 'bsvType': toBsvType(p.type)} for p in m.params]
            methodAction.append(newitem)

    return {
        'Package': os.path.splitext(os.path.basename(self.package))[0],
        'Ifc': self.name,
        'dut': util.decapitalize(name),
        'Dut': util.capitalize(name),
        'methodAction': methodAction,
        'channelCount': self.channelCount,
        'moduleContext': '',

        'requestElements': collectElements(self, collectRequestElement, name),
        'methodRules': collectElements(self, collectMethodRule, name),
        'responseElements': collectElements(self, collectResponseElement, name),
        'indicationMethodRules': collectElements(self, collectIndicationMethodRule, name),
        'indicationMethods': collectElements(self, collectIndicationMethod, name),
        }

def collectElements(self, workerfn, outerTypeName):
    methods = []
    for m in self.decls:
        if m.type == 'Method':
            e = workerfn(m, methsubsts(m, outerTypeName))
            if e:
                methods.append(e)
    return methods

def fixupSubsts(substs):
    substs['methodNames'] = [p['name'] for p in substs['methodAction']]
    substs['requestOutputPipeInterfaces'] = ''.join([requestOutputPipeInterfaceTemplate % {'methodName': methodName,
                                                       'MethodName': util.capitalize(methodName)}
                                                       for methodName in substs['methodNames']])
    substs['portalIfc'] = portalIfcTemplate
    substs['requestElements'] = ''.join(substs['requestElements'])
    substs['requestChannelCount'] = len(substs['methodRules'])
    mkConnectionMethodRules = []
    outputPipes = []
    for m in substs['methodAction']:
        paramsForCall = ['request.%s' % p['name'] for p in m['params']]
        msubs = {'methodName': m['name'],
                 'paramsForCall': ', '.join(paramsForCall)}
        mkConnectionMethodRules.append(mkConnectionMethodTemplate % msubs)
        outputPipes.append('    interface %(methodName)s_PipeOut = toPipeOut(%(methodName)s_requestFifo);' % msubs)
    substs['outputPipes'] = '\n'.join(outputPipes)
    substs['mkConnectionMethodRules'] = ''.join(mkConnectionMethodRules)
    substs['methodRules'] = ''.join(substs['methodRules'])
    substs['responseElements'] = ''.join(substs['responseElements'])
    substs['indicationMethodRules'] = ''.join(substs['indicationMethodRules'])
    substs['indicationMethods'] = ''.join(substs['indicationMethods'])
    substs['indicationChannelCount'] = substs['channelCount']
    return substs

def generate_bsv(project_dir, noisyFlag, jsondata):
    generatedPackageNames = []
    for item in jsondata['interfaces']:
        pname = item['name']
        if pname in generatedPackageNames:
            continue
        generatedPackageNames.append(pname)
        fname = os.path.join(project_dir, 'sources', jsondata['dutname'].lower(), '%s.bsv' % pname)
        bsv_file = util.createDirAndOpen(fname, 'w')
        bsv_file.write('package %s;\n' % pname)
        extraImports = (['import %s::*;\n' % os.path.splitext(os.path.basename(fn))[0] for fn in [item['package']] ]
                   + ['import %s::*;\n' % i for i in jsondata['globalimports'] if not i in generatedPackageNames])
        bsv_file.write(preambleTemplate % {'extraImports' : ''.join(extraImports)})
        if noisyFlag:
            print 'Writing file ', fname
        
        bsv_file.write(exposedWrapperInterfaceTemplate % fixupSubsts(item['Wrapper']))
        bsv_file.write(exposedProxyInterfaceTemplate % fixupSubsts(item['Proxy']))
        bsv_file.write('endpackage: %s\n' % pname)
        bsv_file.close()

