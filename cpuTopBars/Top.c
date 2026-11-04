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

#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <ctype.h>
#include <string.h>
#include <unistd.h>
#include <libproc.h>

#include <sys/param.h>
#include <sys/sysctl.h>
#include <sys/time.h>

#include <mach/mach.h>
#include <mach/task.h>
#include <mach/mach_host.h>
#include <mach/mach_port.h>
#include <mach/mach_types.h>
#include <mach/mach_time.h>

#include "Top.h"
#include "rb.h"

typedef struct _TopProcessInfo _TopProcessInfo_t;
struct _TopProcessInfo
{
  TopProcessSample_t sample;
  rb_node(_TopProcessInfo_t) node_new;
  rb_node(_TopProcessInfo_t) node_sorted;
};

static TopProcessInfo_t _top_process_info;

static uint32_t _top_sequence;
static uint32_t _top_process_count;
static uint64_t _timens;
static uint64_t _top_wall_us;
static uint64_t _top_prev_timens;
static uint64_t _top_prev_wall_us;
static mach_timebase_info_data_t _top_timebase;

// One buffer, kern.argmax bytes: the most KERN_PROCARGS2 returns for a process (see TopInit).
static char *_top_arg_buffer;
static int _top_arg_max;


/* Other users' processes of the latest sample whose CPU could not be read (TopUnreadableCount). */
static int _top_unreadable_count;

static rb_tree(_TopProcessInfo_t) _top_pid_tree;
static rb_tree(_TopProcessInfo_t) _top_sorted_tree;
static boolean_t _top_is_sorted;
static TopOrder _top_order = TopOrderCpu;
static _TopProcessInfo_t* _top_iterator;

static int _top_compare_pid_func(const _TopProcessInfo_t *a, const _TopProcessInfo_t *b)
{
  if (a->sample.pid < b->sample.pid) return -1;
  if (a->sample.pid > b->sample.pid) return 1;
  return 0;
}

static int _top_compare_cpu_func(const _TopProcessInfo_t *a, const _TopProcessInfo_t *b)
{
  if (a->sample.cpu > b->sample.cpu) return -1;
  if (a->sample.cpu < b->sample.cpu) return 1;
  return 0;
}

// Known memory before unknown, then the larger footprint first; ties keep the pid order of the walk.
static int _top_compare_mem_func(const _TopProcessInfo_t *a, const _TopProcessInfo_t *b)
{
  if (a->sample.mem_known != b->sample.mem_known) return (a->sample.mem_known > b->sample.mem_known) ? -1 : 1;
  if (a->sample.mem > b->sample.mem) return -1;
  if (a->sample.mem < b->sample.mem) return 1;
  return 0;
}

// The process with this pid in the pid tree, or NULL.
static _TopProcessInfo_t* _top_find(pid_t pid)
{
  _TopProcessInfo_t probe;
  _TopProcessInfo_t* found;
  probe.sample.pid = pid;
  rb_search(&_top_pid_tree, &probe, _top_compare_pid_func, node_new, found);
  return (found == rb_tree_nil(&_top_pid_tree)) ? NULL : found;
}

TopProcessSample_t* TopGetSample(pid_t pid)
{
  _TopProcessInfo_t* info = _top_find(pid);
  return (info != NULL) ? &info->sample : NULL;
}

// Takes a process out of the pid tree and frees it. Its place in the sorted tree is not touched: only TopSort
// destroys, and it rebuilds that tree.
static void _top_destroy(_TopProcessInfo_t *pinfo)
{
  rb_remove(&_top_pid_tree, pinfo, _TopProcessInfo_t, node_new);
  free(pinfo);
}

// The physical footprint of a process, 1 when read. The task name port is what the App Sandbox allows for
// the user's own processes, and it is enough for TASK_VM_INFO.
static int _top_read_footprint(pid_t pid, uint64_t* footprint)
{
  mach_port_t port = MACH_PORT_NULL;
  if (task_name_for_pid(mach_task_self(), pid, &port) != KERN_SUCCESS)
  {
    return 0;
  }
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  int read = 0;
  if ((task_info(port, TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) && (count >= TASK_VM_INFO_REV1_COUNT))
  {
    *footprint = info.phys_footprint;
    read = 1;
  }
  mach_port_deallocate(mach_task_self(), port);
  return read;
}

// Identity (name, uid, ppid, status) comes from proc_pidinfo(PROC_PIDT_SHORTBSDINFO), which works for
// every process. CPU time and start time come from proc_pidinfo(PROC_PIDTASKALLINFO), which works only
// for the user's own processes: other users' processes (root daemons, WindowServer...) are unknown
// (cpu_known 0). Both are much cheaper than sysctl(KERN_PROC_PID). Memory comes from the task name port,
// for the user's own processes too.
static int __attribute__((noinline)) _top_update_for_pid(pid_t pid)
{
  struct proc_bsdshortinfo bsdinfo;
  if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsdinfo, PROC_PIDT_SHORTBSDINFO_SIZE) != PROC_PIDT_SHORTBSDINFO_SIZE)
  {
    return (-2);
  }
  
  if (bsdinfo.pbsi_status == SZOMB)
  {
    return (-3);
  }
  
  _TopProcessInfo_t* pinfo = _top_find(pid);
  if (pinfo == NULL)
  {
    pinfo = (_TopProcessInfo_t *)calloc(1, sizeof(_TopProcessInfo_t));
    if (pinfo == NULL)
    {
      return (-1);
    }
    pinfo->sample.pid = pid;
    rb_node_new(&_top_pid_tree, pinfo, node_new);
    rb_insert(&_top_pid_tree, pinfo, _top_compare_pid_func, _TopProcessInfo_t, node_new);
  }
  TopProcessSample_t* sample = &pinfo->sample;
  
  sample->sequence = _top_sequence;
  sample->uid = bsdinfo.pbsi_uid;
  sample->ppid = bsdinfo.pbsi_ppid;
  sample->status = bsdinfo.pbsi_status;
  sample->flags = bsdinfo.pbsi_flags;
  sample->tprio = 0;
  snprintf(sample->name, sizeof(sample->name), "%.*s", (int)sizeof(bsdinfo.pbsi_comm), bsdinfo.pbsi_comm);
  
  struct proc_taskallinfo pidinfo;
  if (proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &pidinfo, PROC_PIDTASKALLINFO_SIZE) != PROC_PIDTASKALLINFO_SIZE)
  {
    // another user's process: macOS gives a sandboxed app no CPU time for it
    sample->cpu = 0.0;
    sample->cpu_known = 0;
    sample->mem = 0;
    sample->mem_known = 0;
    sample->start_us = 0;
    sample->last_timens = 0;
    return (0);
  }
  
  uint64_t start_us = (pidinfo.pbsd.pbi_start_tvsec * USEC_PER_SEC) + pidinfo.pbsd.pbi_start_tvusec;
  if (sample->start_us != start_us)
  {
    // first sight, or the pid now belongs to a new process
    sample->start_us = start_us;
    if ((_top_prev_timens != 0) && (start_us >= _top_prev_wall_us))
    {
      // started after the previous sample: all of its CPU time was used since then
      sample->total_timens = 0;
      sample->last_timens = _top_prev_timens;
    }
    else
    {
      // older than the previous sample (or this is the first sample): no baseline yet
      sample->last_timens = 0;
    }
  }
  
  if (pidinfo.pbsd.pbi_name[0] != '\0')
  {
    snprintf(sample->name, sizeof(sample->name), "%.*s", (int)sizeof(pidinfo.pbsd.pbi_name), pidinfo.pbsd.pbi_name);
  }
  sample->tprio = pidinfo.ptinfo.pti_priority;
  sample->status = pidinfo.pbsd.pbi_status;
  sample->flags = pidinfo.pbsd.pbi_flags;
  
  // live and terminated threads in one read, in mach_absolute_time units, so it cannot go backwards
  uint64_t total_timens = ((pidinfo.ptinfo.pti_total_user + pidinfo.ptinfo.pti_total_system) * _top_timebase.numer) / _top_timebase.denom;
  if ((sample->last_timens != 0) && (_timens > sample->last_timens) && (total_timens >= sample->total_timens))
  {
    sample->cpu = (double)(total_timens - sample->total_timens) * 100.0 / (double)(_timens - sample->last_timens);
  }
  else
  {
    sample->cpu = 0.0;
  }
  sample->cpu_known = 1;
  uint64_t footprint = 0;
  if (_top_read_footprint(pid, &footprint))
  {
    sample->mem = footprint;
    sample->mem_known = 1;
  }
  else
  {
    sample->mem = 0;
    sample->mem_known = 0;
  }
  sample->total_timens = total_timens;
  sample->last_timens = _timens;
  
  return (0);
}

int TopInit(void)
{
  if ((mach_timebase_info(&_top_timebase) != KERN_SUCCESS) || (_top_timebase.denom == 0))
  {
    _top_timebase.numer = 1;
    _top_timebase.denom = 1;
  }
  
  _top_sequence = 0;

  // kern.argmax is the most bytes KERN_PROCARGS2 can return for one process; one buffer of that size is reused for
  // every read. Without the value or the buffer TopGetArgs reads no arguments, and sampling still works.
  int argmax_name[2] = { CTL_KERN, KERN_ARGMAX };
  size_t argmax_size = sizeof(_top_arg_max);
  if ((sysctl(argmax_name, 2, &_top_arg_max, &argmax_size, NULL, 0) == -1) || (_top_arg_max <= 0))
  {
    _top_arg_max = 0;
  }
  _top_arg_buffer = (_top_arg_max > 0) ? (char *)malloc(_top_arg_max) : NULL;

  rb_tree_new(&_top_pid_tree, node_new);

  memset(&_top_process_info, 0, sizeof(TopProcessInfo_t));

  return TopSample();
}

// Builds the sorted tree from the processes the latest sample saw, counts them and the unreadable ones, and frees
// the processes that were not seen. The pid tree is walked with the next node read first, since a stale one is freed.
static void TopSort(void)
{
  int (*before)(const _TopProcessInfo_t*, const _TopProcessInfo_t*) =
    (_top_order == TopOrderMemory) ? _top_compare_mem_func : _top_compare_cpu_func;

  _top_iterator = NULL;
  _top_is_sorted = 1;
  _top_process_count = 0;
  _top_unreadable_count = 0;
  rb_tree_new(&_top_sorted_tree, node_sorted);

  _TopProcessInfo_t* node;
  rb_first(&_top_pid_tree, node_new, node);
  while (node != rb_tree_nil(&_top_pid_tree))
  {
    _TopProcessInfo_t* following;
    rb_next(&_top_pid_tree, node, _TopProcessInfo_t, node_new, following);
    if (node->sample.sequence != _top_sequence)
    {
      _top_destroy(node);
    }
    else
    {
      rb_node_new(&_top_sorted_tree, node, node_sorted);
      rb_insert(&_top_sorted_tree, node, before, _TopProcessInfo_t, node_sorted);
      _top_process_count++;
      if ((node->sample.cpu_known == 0) && (node->sample.uid != getuid()))
      {
        _top_unreadable_count++;
      }
    }
    node = following;
  }
}

void TopSetOrder(TopOrder order)
{
  _top_order = (order == TopOrderMemory) ? TopOrderMemory : TopOrderCpu;
  if (_top_sequence != 0)
  {
    TopSort();
  }
}

int TopUnreadableCount(void)
{
  return _top_unreadable_count;
}

// Lists the processes with sysctl(KERN_PROC_ALL), which the App Sandbox allows where the libproc list gives
// none. The buffer is kept and grown with slack for processes started between the size query and the read;
// ENOMEM (the list outgrew the slack) asks again. Returns the entry count, -1 on failure.
static int _top_list_processes(const struct kinfo_proc** list)
{
  static struct kinfo_proc* buffer = NULL;
  static size_t capacity = 0;
  int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };

  for (int attempt = 0; attempt < 3; attempt++)
  {
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0)
    {
      return -1;
    }
    size += size / 8;
    if (size > capacity)
    {
      struct kinfo_proc* grown = realloc(buffer, size);
      if (grown == NULL)
      {
        return -1;
      }
      buffer = grown;
      capacity = size;
    }
    size_t length = capacity;
    if (sysctl(mib, 4, buffer, &length, NULL, 0) == 0)
    {
      *list = buffer;
      return (int)(length / sizeof(struct kinfo_proc));
    }
    if (errno != ENOMEM)
    {
      return -1;
    }
  }
  return -1;
}

int TopSample(void)
{
  // the list first: when it cannot be read, the previous sample, its sort and its baselines stand
  static bool list_failed = false;
  const struct kinfo_proc* list = NULL;
  int num_pids = _top_list_processes(&list);
  if (num_pids < 0)
  {
    if (!list_failed)
    {
      fprintf(stderr, "sysctl(KERN_PROC_ALL) failed: %s\n", strerror(errno));
      list_failed = true;
    }
    _top_iterator = NULL;
    return _top_process_count;
  }
  list_failed = false;

  _top_sequence++;

  _top_iterator = NULL;

  _top_is_sorted = 0;

  _top_prev_timens = _timens;
  _top_prev_wall_us = _top_wall_us;
  _timens = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
  {
    // wall clock, to compare with the process start times (pbi_start_tvsec)
    struct timeval tv;
    gettimeofday(&tv, NULL);
    _top_wall_us = ((uint64_t)tv.tv_sec * USEC_PER_SEC) + (uint64_t)tv.tv_usec;
  }

  for (int i=0; i<num_pids; i++)
  {
    pid_t pid = list[i].kp_proc.p_pid;
    int err = _top_update_for_pid(pid);
    // -2 (exited since the list was taken) and -3 (zombie) are expected
    if ((err != 0) && (err != -2) && (err != -3))
    {
      fprintf(stderr, "_top_update_for_pid(%d) returned %d\n", pid, err);
    }
  }

  TopSort();
  
  return _top_process_count;
}

// Walks the sorted tree; before the first sort there is nothing to walk. The walk ends with NULL and the next
// call starts again at the first process.
const TopProcessSample_t* TopIterate(void)
{
  if (!_top_is_sorted)
  {
    return NULL;
  }
  _TopProcessInfo_t* node = _top_iterator;
  if (node == NULL)
  {
    rb_first(&_top_sorted_tree, node_sorted, node);
  }
  else
  {
    rb_next(&_top_sorted_tree, node, _TopProcessInfo_t, node_sorted, node);
  }
  _top_iterator = (node == rb_tree_nil(&_top_sorted_tree)) ? NULL : node;
  return (_top_iterator != NULL) ? &_top_iterator->sample : NULL;
}

void TopIterateReset(void)
{
  _top_iterator = NULL;
}

// The next NUL-terminated string at *data, before end; NULL when none is left or it has no NUL before end
// (a process can overwrite its own string area and leave none).
static char* _top_next_string(char** data, char* end, size_t* length)
{
  char* string = *data;
  if (string >= end)
  {
    return NULL;
  }
  char* nul = memchr(string, '\0', (size_t)(end - string));
  if (nul == NULL)
  {
    return NULL;
  }
  *length = (size_t)(nul - string);
  *data = nul + 1;
  return string;
}

// Appends length bytes of string and a newline to *buffer, which holds *used characters and a NUL. False when
// out of memory (the buffer keeps what it had).
static bool _top_append_line(char** buffer, int* used, const char* string, size_t length)
{
  char* grown = realloc(*buffer, (size_t)*used + length + 2);
  if (grown == NULL)
  {
    return false;
  }
  memcpy(grown + *used, string, length);
  grown[*used + length] = '\n';
  grown[*used + length + 1] = '\0';
  *buffer = grown;
  *used += (int)(length + 1);
  return true;
}

// http://search.cpan.org/src/DURIST/Proc-ProcessTable-0.43/os/darwin.c
TopProcessInfo_t* TopGetArgs(pid_t pid)
{  
  _top_process_info.args_count = 0;
  _top_process_info.args_length = 0;
  _top_process_info.envs_count = 0;
  _top_process_info.envs_length = 0;
  // KERN_PROCARGS2 fails for other users' processes: never leave the previous process's text behind
  if (_top_process_info.command != NULL)
  {
    _top_process_info.command[0] = '\0';
  }
  if (_top_process_info.args_info != NULL)
  {
    _top_process_info.args_info[0] = '\0';
  }
  if (_top_process_info.envs_info != NULL)
  {
    _top_process_info.envs_info[0] = '\0';
  }

  int mib[3];
  mib[0] = CTL_KERN;
  mib[1] = KERN_PROCARGS2;
  mib[2] = pid;
  size_t size = _top_arg_max;
  if ((_top_arg_buffer != NULL) && (sysctl(mib, 3, _top_arg_buffer, &size, NULL, 0) == 0) && (size >= sizeof(int)))
  {
    // argc; the executable's path and its NUL padding; argc arguments; the environment up to the first empty
    // string; then empty strings and the kernel's own apple[] strings (ptr_munge=, executable_cdhash= ...),
    // which are not environment. Every string is read up to end, never with strlen.
    char* data = _top_arg_buffer;
    char* end = _top_arg_buffer + size;
    int argc = 0;
    memcpy(&argc, data, sizeof(int));
    data += sizeof(int);
    _top_process_info.args_count = (argc > 0) ? argc : 0;

    size_t length = 0;
    char* string = _top_next_string(&data, end, &length);
    if (string != NULL)
    {
      char* command = realloc(_top_process_info.command, length+1);
      if (command != NULL)
      {
        memcpy(command, string, length);
        command[length] = '\0';
        _top_process_info.command = command;
      }

      // the padding after the path
      while ((data < end) && (data[0] == '\0'))
      {
        data++;
      }

      // argc arguments; an empty one counts, and is not shown
      int index = 0;
      while ((index < _top_process_info.args_count) && ((string = _top_next_string(&data, end, &length)) != NULL))
      {
        if ((length > 0) && !_top_append_line(&_top_process_info.args_info, &_top_process_info.args_length, string, length))
        {
          break;
        }
        index++;
      }

      // the environment, only when every argument was found
      if (index == _top_process_info.args_count)
      {
        while (((string = _top_next_string(&data, end, &length)) != NULL) && (length > 0))
        {
          if (!_top_append_line(&_top_process_info.envs_info, &_top_process_info.envs_length, string, length))
          {
            break;
          }
          _top_process_info.envs_count++;
        }
      }
    }
  }
  
  // the name the latest sample read (up to 32 characters for the user's own processes, 16 for the others); a process
  // started since that sample is read directly, by the 16-character name every process gives
  const char* found = NULL;
  size_t name_length = 0;
  struct proc_bsdshortinfo shortinfo;
  TopProcessSample_t* sample = TopGetSample(pid);
  if (sample != NULL)
  {
    found = sample->name;
    name_length = strnlen(sample->name, sizeof(sample->name));
  }
  else if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &shortinfo, PROC_PIDT_SHORTBSDINFO_SIZE) == PROC_PIDT_SHORTBSDINFO_SIZE)
  {
    found = shortinfo.pbsi_comm;
    name_length = strnlen(shortinfo.pbsi_comm, sizeof(shortinfo.pbsi_comm));
  }
  char* name = (name_length > 0) ? realloc(_top_process_info.name, name_length + 1) : NULL;
  if (name == NULL)
  {
    if (_top_process_info.name != NULL)
    {
      _top_process_info.name[0] = '\0';
    }
    return &_top_process_info;
  }
  memcpy(name, found, name_length);
  name[name_length] = '\0';
  _top_process_info.name = name;
  return &_top_process_info;
}

// Reads the digits of one number (an optional fraction when allowed) and moves *s past it; false when none.
static bool ParseTopNumber(const char **s, double *value, bool *has_fraction)
{
  const char *p = *s;
  if (!isdigit((unsigned char)*p)) return false;
  double v = 0.0;
  while (isdigit((unsigned char)*p))
  {
    v = (v * 10.0) + (*p++ - '0');
    if (v > 4294967295.0) return false;
  }
  bool fraction = false;
  if (*p == '.')
  {
    p++;
    if (!isdigit((unsigned char)*p)) return false;
    fraction = true;
    double scale = 0.1;
    while (isdigit((unsigned char)*p))
    {
      v += (*p++ - '0') * scale;
      scale /= 10.0;
    }
  }
  if (*p != '\0' && !isspace((unsigned char)*p)) return false;
  *s = p;
  *value = v;
  *has_fraction = fraction;
  return true;
}

// A row is: spaces, pid, [uid,] cpu (digits with a fraction), then, when top was given the command column, the name.
// With a uid column the second number has no fraction and a third number follows; without one the second is the CPU.
int TopParseTopLine(const char *line, TopParsedRow_t *out)
{
  if ((line == NULL) || (out == NULL)) return 0;
  const char *s = line;
  while (isspace((unsigned char)*s)) s++;
  double pid = 0.0, second = 0.0, third = 0.0;
  bool fraction = false;
  if (!ParseTopNumber(&s, &pid, &fraction) || fraction || (pid > 2147483647.0)) return 0;
  if (!isspace((unsigned char)*s)) return 0;
  while (isspace((unsigned char)*s)) s++;
  if (!ParseTopNumber(&s, &second, &fraction)) return 0;
  bool has_uid = false;
  double cpu = second;
  if (!fraction)
  {
    // the second number is a uid only when a CPU figure follows it
    const char *t = s;
    while (isspace((unsigned char)*t)) t++;
    bool third_fraction = false;
    if (!ParseTopNumber(&t, &third, &third_fraction)) return 0;
    has_uid = true;
    cpu = third;
    s = t;
  }
  while (isspace((unsigned char)*s)) s++;
  size_t length = strlen(s);
  while ((length > 0) && isspace((unsigned char)s[length - 1])) length--;
  if (length >= TOP_PARSED_NAME_SIZE) length = TOP_PARSED_NAME_SIZE - 1;
  out->pid = (pid_t)pid;
  out->has_uid = has_uid ? 1 : 0;
  out->uid = has_uid ? (uid_t)second : 0;
  out->cpu = cpu;
  memcpy(out->name, s, length);
  out->name[length] = '\0';
  return 1;
}

// Whether the app may offer to end a process: not pid 0 (the kernel) or 1 (launchd), not itself, and only a process of
// the user running it. Pure, so both variants and the tests reach it; only the unsandboxed app calls kill().
int KillAllowed(pid_t pid, uid_t uid, pid_t self, uid_t me)
{
  return (pid > 1) && (pid != self) && (uid == me);
}
