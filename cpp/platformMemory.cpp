
// Copyright (c) 2013-2014 Quanta Research Cambridge, Inc.

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
#include <assert.h>
#include "dmaManager.h"
#include "MMURequest.h"
#include "MMUIndication.h"
#include "MemServerRequest.h"
#include "MemServerIndication.h"

class PortalPoller;

static int mmu_error_limit = 20;
static int mem_error_limit = 20;
class MMUIndication : public MMUIndicationWrapper
{
  DmaManager *portalMemory;
 public:
  MMUIndication(DmaManager *pm, unsigned int  id) : MMUIndicationWrapper(id), portalMemory(pm) {}
  MMUIndication(DmaManager *pm, unsigned int  id, PortalTransportFunctions *item, void *param) : MMUIndicationWrapper(id, item, param), portalMemory(pm) {}
  virtual void configResp(uint32_t pointer){
    fprintf(stderr, "MMUIndication::configResp: %x\n", pointer);
    portalMemory->confResp(pointer);
  }
  virtual void error (uint32_t code, uint32_t pointer, uint64_t offset, uint64_t extra) {
    fprintf(stderr, "MMUIndication::error(code=0x%x, pointer=0x%x, offset=0x%"PRIx64" extra=-0x%"PRIx64"\n", code, pointer, offset, extra);
    if (--mmu_error_limit < 0)
        exit(-1);
  }
  virtual void idResponse(uint32_t sglId){
    portalMemory->sglIdResp(sglId);
  }
};

class MemServerIndication : public MemServerIndicationWrapper
{
  MemServerRequestProxy *memServerRequestProxy;
  sem_t mtSem;
  uint64_t mtCnt;
  void init(){
    if (sem_init(&mtSem, 0, 0))
      PORTAL_PRINTF("MemServerIndication::init failed to init mtSem\n");
  }
 public:
  MemServerIndication(unsigned int  id) : MemServerIndicationWrapper(id), memServerRequestProxy(NULL) {init();}
  MemServerIndication(MemServerRequestProxy *p, unsigned int  id) : MemServerIndicationWrapper(id), memServerRequestProxy(p) {init();}
  virtual void addrResponse(uint64_t physAddr){
    fprintf(stderr, "DmaIndication::addrResponse(physAddr=%"PRIx64")\n", physAddr);
  }
  virtual void reportStateDbg(const DmaDbgRec rec){
    fprintf(stderr, "MemServerIndication::reportStateDbg: {x:%08x y:%08x z:%08x w:%08x}\n", rec.x,rec.y,rec.z,rec.w);
  }
  virtual void reportMemoryTraffic(uint64_t words){
    //fprintf(stderr, "reportMemoryTraffic: words=%"PRIx64"\n", words);
    mtCnt = words;
    sem_post(&mtSem);
  }
  virtual void error (uint32_t code, uint32_t pointer, uint64_t offset, uint64_t extra) {
    fprintf(stderr, "MemServerIndication::error(code=%x, pointer=%x, offset=%"PRIx64" extra=%"PRIx64"\n", code, pointer, offset, extra);
    if (--mem_error_limit < 0)
      exit(-1);
  }
  uint64_t receiveMemoryTraffic(){
    sem_wait(&mtSem);
    return mtCnt; 
  }
  uint64_t getMemoryTraffic(const ChannelType rc){
    assert(memServerRequestProxy);
    memServerRequestProxy->memoryTraffic(rc);
    return receiveMemoryTraffic();
  }
};

static MemServerRequestProxy *hostMemServerRequest;
static MemServerIndication *hostMemServerIndication;
static MMUIndication *mmuIndication;
DmaManager *platformInit(void)
{
    hostMemServerRequest = new MemServerRequestProxy(IfcNames_MemServerRequestS2H);
    MMURequestProxy *dmap = new MMURequestProxy(IfcNames_MMURequestS2H);
    DmaManager *dma = new DmaManager(dmap);
    hostMemServerIndication = new MemServerIndication(hostMemServerRequest, IfcNames_MemServerIndicationH2S);
    mmuIndication = new MMUIndication(dma, IfcNames_MMUIndicationH2S);

#ifdef FPGA0_CLOCK_FREQ
    long req_freq = FPGA0_CLOCK_FREQ;
    long freq = 0;
    setClockFrequency(0, req_freq, &freq);
    fprintf(stderr, "Requested FCLK[0]=%ld actually %ld\n", req_freq, freq);
#endif
    return dma;
}

void platformStatistics(void)
{
    uint64_t cycles = portalTimerLap(0);
    hostMemServerRequest->memoryTraffic(ChannelType_Read);
    uint64_t beats = hostMemServerIndication->receiveMemoryTraffic();
    float read_util = (float)beats/(float)cycles;
    fprintf(stderr, "   beats: %llx\n", (long long)beats);
    fprintf(stderr, "memory utilization (beats/cycle): %f\n", read_util);
}