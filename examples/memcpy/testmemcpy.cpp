/* Copyright (c) 2013 Quanta Research Cambridge, Inc
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
#include <stdio.h>
#include <sys/mman.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <pthread.h>
#include <monkit.h>
#include <semaphore.h>
#include "StdDmaIndication.h"

#include "DmaConfigProxy.h"
#include "GeneratedTypes.h"
#include "MemcpyIndicationWrapper.h"
#include "MemcpyRequestProxy.h"

sem_t done_sem;
PortalAlloc *srcAlloc;
PortalAlloc *dstAlloc;
unsigned int *srcBuffer = 0;
unsigned int *dstBuffer = 0;
#ifdef MMAP_HW
int numWords = 16 << 18;
#else
int numWords = 16 << 10;
#endif
size_t alloc_sz = numWords*sizeof(unsigned int);
bool finished = false;
bool memcmp_fail = false;
unsigned int memcmp_count = 0;

void dump(const char *prefix, char *buf, size_t len)
{
    fprintf(stderr, "%s ", prefix);
    for (int i = 0; i < len ; i++) {
	fprintf(stderr, "%02x", (unsigned char)buf[i]);
	if (i % 32 == 31)
	  fprintf(stderr, "\n");
    }
    fprintf(stderr, "\n");
}

class MemcpyIndication : public MemcpyIndicationWrapper
{

public:
  MemcpyIndication(const char* devname, unsigned int addrbits) : MemcpyIndicationWrapper(devname,addrbits){}
  MemcpyIndication(unsigned int id) : MemcpyIndicationWrapper(id){}


  virtual void started(unsigned long words){
    fprintf(stderr, "started: words=%ld\n", words);
  }
  virtual void done(unsigned long mismatch) {
    sem_post(&done_sem);
    fprintf(stderr, "done: mismatch=%d\n", mismatch);
    finished = true;
    memcmp_fail |= mismatch;
    //unsigned int mcf = memcmp(srcBuffer, dstBuffer, numWords*sizeof(unsigned int));
    //memcmp_fail |= mcf;
    //if(true){
    //fprintf(stderr, "memcpy done: %lx\n", v);
    // fprintf(stderr, "(%d) memcmp src=%lx dst=%lx success=%s\n", memcmp_count, (long)srcBuffer, (long)dstBuffer, mcf == 0 ? "pass" : "fail");
      //dump("src", (char*)srcBuffer, 128);
      //dump("dst", (char*)dstBuffer, 128);
    // }
  }
  virtual void rData ( unsigned long long v ){
    //fprintf(stderr, "rData: %016llx\n", v);
  }
  virtual void readReq(unsigned long v){
    //fprintf(stderr, "readReq %lx\n", v);
  }
  virtual void writeReq(unsigned long v){
    //fprintf(stderr, "writeReq %lx\n", v);
  }
  virtual void writeAck(unsigned long v){
    //fprintf(stderr, "writeAck %lx\n", v);
  }
  virtual void reportStateDbg(unsigned long streamRdCnt, 
			      unsigned long streamWrCnt, 
			      unsigned long dataMismatch){
    fprintf(stderr, "Memcpy::reportStateDbg: streamRdCnt=%ld, streamWrCnt=%ld, dataMismatch=%ld\n", 
	    streamRdCnt, streamWrCnt, dataMismatch);
  }  
};


// we can use the data synchronization barrier instead of flushing the 
// cache only because the ps7 is configured to run in buffered-write mode
//
// an opc2 of '4' and CRm of 'c10' encodes "CP15DSB, Data Synchronization Barrier 
// operation". this is a legal instruction to execute in non-privileged mode (mdk)
//
// #define DATA_SYNC_BARRIER   __asm __volatile( "MCR p15, 0, %0, c7, c10, 4" ::  "r" (0) );

int main(int argc, const char **argv)
{
  MemcpyRequestProxy *device = 0;
  DmaConfigProxy *dma = 0;
  
  MemcpyIndication *deviceIndication = 0;
  DmaIndication *dmaIndication = 0;

  if(sem_init(&done_sem, 1, 0)){
    fprintf(stderr, "failed to init done_sem\n");
    exit(1);
  }

  fprintf(stderr, "%s %s\n", __DATE__, __TIME__);

  device = new MemcpyRequestProxy(IfcNames_MemcpyRequest);
  dma = new DmaConfigProxy(IfcNames_DmaConfig);

  deviceIndication = new MemcpyIndication(IfcNames_MemcpyIndication);
  dmaIndication = new DmaIndication(dma, IfcNames_DmaIndication);

  fprintf(stderr, "Main::allocating memory...\n");

  dma->alloc(alloc_sz, &srcAlloc);
  dma->alloc(alloc_sz, &dstAlloc);

  // for(int i = 0; i < srcAlloc->header.numEntries; i++)
  //   fprintf(stderr, "%lx %lx\n", srcAlloc->entries[i].dma_address, srcAlloc->entries[i].length);
  // for(int i = 0; i < dstAlloc->header.numEntries; i++)
  //   fprintf(stderr, "%lx %lx\n", dstAlloc->entries[i].dma_address, dstAlloc->entries[i].length);

  srcBuffer = (unsigned int *)mmap(0, alloc_sz, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_SHARED, srcAlloc->header.fd, 0);
  dstBuffer = (unsigned int *)mmap(0, alloc_sz, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_SHARED, dstAlloc->header.fd, 0);

  pthread_t tid;
  fprintf(stderr, "creating exec thread\n");
  if(pthread_create(&tid, NULL,  portalExec, NULL)){
    fprintf(stderr, "error creating exec thread\n");
    exit(1);
  }

  for (int i = 0; i < numWords; i++){
    srcBuffer[i] = i;
    dstBuffer[i] = 0x5a5abeef;
  }

  dma->dCacheFlushInval(srcAlloc, srcBuffer);
  dma->dCacheFlushInval(dstAlloc, dstBuffer);
  fprintf(stderr, "Main::flush and invalidate complete\n");

  unsigned int ref_srcAlloc = dma->reference(srcAlloc);
  unsigned int ref_dstAlloc = dma->reference(dstAlloc);
  
  sleep(1);
  dma->addrRequest(ref_srcAlloc, 1*sizeof(unsigned int));
  sleep(1);
  dma->addrRequest(ref_dstAlloc, 2*sizeof(unsigned int));
  sleep(1);
  
  fprintf(stderr, "Main::starting mempcy numWords:%d\n", numWords);
  int burstLen = 16;
#ifdef MMAP_HW
  int iterCnt = 32;
#else
  int iterCnt = 2;
#endif
  start_timer(0);
  device->startCopy(ref_dstAlloc, ref_srcAlloc, numWords, burstLen, iterCnt);
  sem_wait(&done_sem);
  unsigned long long cycles = lap_timer(0);
  unsigned long long read_beats = dma->show_mem_stats(ChannelType_Write);
  unsigned long long write_beats = dma->show_mem_stats(ChannelType_Write);
  fprintf(stderr, "memory read utilization (beats/cycle): %f\n", ((float)read_beats)/((float)cycles));
  fprintf(stderr, "memory write utilization (beats/cycle): %f\n", ((float)write_beats)/((float)cycles));
  
  MonkitFile("perf.monkit")
    .setCycles(cycles)
    .setReadBeats(read_beats)
    .setWriteBeats(write_beats)
    .writeFile();

  sleep(2);
  exit(memcmp_fail);
}
