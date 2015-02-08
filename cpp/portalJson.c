// Copyright (c) 2012 Nokia, Inc.
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

#include <string.h>
#include "portal.h"

void connectalJsonEncode(PortalInternal *pint, void *tempdata, ConnectalMethodJsonInfo *info)
{
    ConnectalParamJsonInfo *iparam = info->param;
    char *data = (char *)pint->map_base;
    sprintf(data, "{'name': '%s',", info->name);
    data += strlen(data);
    while(iparam->name) {
        uint32_t tmp32;
        uint64_t tmp64;
        int      tmpint;
        sprintf(data, "'%s':", iparam->name);
        data += strlen(data);
        switch(iparam->itype) {
        case ITYPE_uint32_t:
            tmp32 = *(uint32_t *)((unsigned long)tempdata + iparam->offset);
            sprintf(data, "0x%x,", tmp32);
            data += strlen(data);
            break;
        case ITYPE_uint64_t:
            tmp64 = *(uint64_t *)((unsigned long)tempdata + iparam->offset);
            sprintf(data, "0x%lx,", (unsigned long)tmp64);
            data += strlen(data);
            break;
        case ITYPE_SpecialTypeForSendingFd:
            tmpint = *(int *)((unsigned long)tempdata + iparam->offset);
            sprintf(data, "%d,", tmpint);
            data += strlen(data);
            break;
        default:
            printf("%x type %d\n", *(uint32_t *)((unsigned long)tempdata + iparam->offset), iparam->itype);
        }
        iparam++;
    }
    sprintf(data, "}");
    data += strlen(data);
//printf("[%s:%d] num %d message \"%s\"\n", __FUNCTION__, __LINE__, iparam->offset, (char *)pint->map_base);
    pint->item->send(pint, pint->map_base, (iparam->offset << 16) | strlen((char *)pint->map_base), -1);
}

void connnectalJsonDecode(PortalInternal *pint, int channel, void *tempdata, ConnectalMethodJsonInfo *info)
{
    uint32_t header = *(uint32_t *)pint->map_base;
    char *datap = (char *)pint->map_base;
    char ch, *attr = NULL, *val = NULL;
    int tmpfd;
//printf("[%s:%d] header %x name %s\n", __FUNCTION__, __LINE__, header, info->name);
    int len = pint->item->recv(pint, pint->map_base, (header & 0xffff)-1, &tmpfd);
    datap[len] = 0;
    while ((ch = *datap++)) {
        if (ch == '\'') {
            if (!attr)
                attr = datap;
            else if (!val)
                *(datap - 1) = 0;
        }
        else if (ch == ':')
            val = datap;
        else if ((ch == ',' || ch == '}') && attr && val) {
            *(datap - 1) = 0;
            ConnectalParamJsonInfo *iparam = info->param;
            while (iparam->name) {
                if (!strcmp(iparam->name, attr)) {
                    char *endptr;
                    uint64_t tmp64 = strtol(val, &endptr, 0);
                    switch(iparam->itype) {
                    case ITYPE_uint32_t:
                        *(uint32_t *)((unsigned long)tempdata + iparam->offset) = tmp64;
                        break;
                    case ITYPE_uint64_t:
                        *(uint64_t *)((unsigned long)tempdata + iparam->offset) = tmp64;
                        break;
                    case ITYPE_SpecialTypeForSendingFd:
                        *(int *)((unsigned long)tempdata + iparam->offset) = tmp64;
                        break;
                    default:
                        printf("%x type %d\n", *(uint32_t *)((unsigned long)tempdata + iparam->offset), iparam->itype);
                    }
                    break;
                }
                iparam++;
            }
            attr = NULL;
            val = NULL;
        }
    }
}
