// The MIT License (MIT)

// Copyright 2022 HalfMarble LLC

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#ifndef Top_h
#define Top_h

#include <sys/types.h>

__BEGIN_DECLS

#define TOP_MAX_SAMPLE_NAME_SIZE (128)
#define TOP_MAX_INFO_NAME_SIZE (4096)

typedef struct TopProcessSample TopProcessSample_t;
struct TopProcessSample
{
  uid_t    uid;
  pid_t    pid;
  pid_t    ppid;
  int32_t  tprio;
  uint32_t status;
  uint32_t flags;
  char     name[TOP_MAX_SAMPLE_NAME_SIZE+1];
  double   cpu;          // % of one core since the previous read, 0 when there is no baseline
  int      cpu_known;    // 0 = unknown (the App Sandbox gives no CPU time for another user's process),
                         // 1 = measured
  uint64_t mem;          // physical footprint in bytes (phys_footprint, the figure footprint(1) reports), 0 when unknown
  int      mem_known;    // 0 = unknown (another user's process, or the read failed),
                         // 1 = read

  uint32_t sequence;

  uint64_t start_us;     // process start time, a change means the pid was reused
  uint64_t total_timens; // CPU time at the last read
  uint64_t last_timens;  // wall time of the last read, 0 = no baseline yet
};

typedef struct TopProcessInfo TopProcessInfo_t;
struct TopProcessInfo
{  
  char* name;
  char* command;

  char* args_info;
  int args_count;
  int args_length;

  char* envs_info;
  int envs_count;
  int envs_length;
};

int TopInit(void);
int TopSample(void);
const TopProcessSample_t* TopIterate(void);
// Starts the next TopIterate walk at the first process again.
void TopIterateReset(void);
TopProcessInfo_t* TopGetArgs(pid_t pid);
TopProcessSample_t* TopGetSample(pid_t pid);
// The number of other users' processes in the latest sample whose CPU is unknown (cpu_known 0).
int TopUnreadableCount(void);

// One process row of /usr/bin/top's output, as `-stats pid,cpu` or `-stats pid,uid,cpu,command` prints it.
#define TOP_PARSED_NAME_SIZE (64)
typedef struct TopParsedRow TopParsedRow_t;
struct TopParsedRow
{
  pid_t  pid;
  int    has_uid;     // 1 when the row carries a uid column
  uid_t  uid;         // 0 when has_uid is 0
  double cpu;         // % of one core
  char   name[TOP_PARSED_NAME_SIZE]; // the command column as top prints it (it may hold spaces and is cut by top), "" when absent
};
// Parses one line of /usr/bin/top's output (no newline). Returns 1 and fills *out for a process row,
// 0 for a header, a summary line, a blank line or anything else. Pure: no globals, no I/O.
int TopParseTopLine(const char *line, TopParsedRow_t *out);

// Whether the app may offer to end the process pid, owned by uid: pid above 1, not self, and uid equal to me.
int KillAllowed(pid_t pid, uid_t uid, pid_t self, uid_t me);

typedef enum { TopOrderCpu = 0, TopOrderMemory = 1 } TopOrder;
// Sets the order TopIterate walks the sample in, and sorts the latest sample again if there is one.
void TopSetOrder(TopOrder order);

__END_DECLS

#endif /* Top_h */
