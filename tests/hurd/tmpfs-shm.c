/* Shared memory on a tmpfs: the patterns Wayland clients and shm_open users
   rely on, and the file semantics they must not break.

   Usage: tmpfs-shm DIRECTORY [CYCLES]
   TMPFS_SHM_ONLY=N runs only case N.

   Each case runs in a child process, so that a SIGBUS fails that case
   instead of the whole run.  The output is TAP.  It runs on Linux too
   (DIRECTORY=/dev/shm), which checks the expectations themselves.

   On a tmpfs that shrinks the memory object of an unlinked file at its
   last close, the mappings that outlive the close get SIGBUS.  On a GNU
   Mach without the default pager fixes of its hurdkit branch, the shrink
   cases stop the kernel in its debugger (vm_map_copyin_page_list:
   Assertion `m->wire_count == 1'), and the msync cases lose the pages of
   a guest that has no swap.

   Nothing here puts the guest under memory pressure: without swap, pages
   that the kernel evicts are still lost.  */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/statvfs.h>
#include <sys/wait.h>
#include <unistd.h>

#define PAGES 64
#define SIGBUS_EXIT 3
/* A case that has not finished after this many seconds fails.  */
#define CASE_TIMEOUT 120

static const char *directory;
static size_t page_size;
static int test_number;
static int failures;

static void
bus_error (int signal_number)
{
  (void) signal_number;
  _exit (SIGBUS_EXIT);
}

static int
fail (const char *what)
{
  fprintf (stderr, "# %s: %s\n", what, strerror (errno));
  return 1;
}

/* Open a new file in DIRECTORY; unlink it unless KEEP_LINK.  */
static int
new_file (int keep_link, char *path, size_t size)
{
  static unsigned serial;
  snprintf (path, size, "%s/.tmpfs-shm-%ld-%u", directory, (long) getpid (),
            serial++);
  int fd = open (path, O_RDWR | O_CREAT | O_EXCL, 0600);
  if (fd >= 0 && !keep_link && unlink (path) < 0)
    {
      close (fd);
      return -1;
    }
  return fd;
}

static unsigned char
pattern (size_t offset, unsigned seed)
{
  return (unsigned char) ((offset / 7) * 31U + seed);
}

static void
fill (unsigned char *data, size_t length, size_t base, unsigned seed)
{
  for (size_t i = 0; i < length; i++)
    data[i] = pattern (base + i, seed);
}

static int
check (const unsigned char *data, size_t length, size_t base, unsigned seed)
{
  for (size_t i = 0; i < length; i++)
    if (data[i] != pattern (base + i, seed))
      {
        fprintf (stderr, "# byte %zu is %u, expected %u\n", base + i,
                 data[i], pattern (base + i, seed));
        return 1;
      }
  return 0;
}

/* An unlinked file, mapped and then closed, as a Wayland client's buffer:
   the mapping keeps the data and takes new writes.  */
static int
mapped_after_close (void)
{
  char path[4096];
  size_t length = PAGES * page_size;
  int fd = new_file (0, path, sizeof path);
  if (fd < 0 || ftruncate (fd, length) < 0)
    return fail ("create");
  unsigned char *map = mmap (NULL, length, PROT_READ | PROT_WRITE,
                             MAP_SHARED, fd, 0);
  if (map == MAP_FAILED)
    return fail ("mmap");
  fill (map, length / 2, 0, 1);
  close (fd);
  fill (map + length / 2, length / 2, length / 2, 1);
  return check (map, length, 0, 1);
}

/* The same through shm_open, the POSIX interface for it.  */
static int
shm_object (void)
{
  size_t length = PAGES * page_size;
#ifdef SHM_ANON
  int fd = shm_open (SHM_ANON, O_RDWR | O_CREAT | O_EXCL, 0600);
#else
  char name[64];
  snprintf (name, sizeof name, "/tmpfs-shm-%ld", (long) getpid ());
  int fd = shm_open (name, O_RDWR | O_CREAT | O_EXCL, 0600);
  if (fd >= 0)
    shm_unlink (name);
#endif
  if (fd < 0 || ftruncate (fd, length) < 0)
    return fail ("shm_open");
  unsigned char *map = mmap (NULL, length, PROT_READ | PROT_WRITE,
                             MAP_SHARED, fd, 0);
  if (map == MAP_FAILED)
    return fail ("mmap");
  close (fd);
  fill (map, length, 0, 2);
  return check (map, length, 0, 2);
}

/* write and read an unlinked file without any mapping.  */
static int
write_read_unlinked (void)
{
  char path[4096];
  size_t length = PAGES * page_size;
  unsigned char *buffer = malloc (length);
  int fd = new_file (0, path, sizeof path);
  if (fd < 0 || buffer == NULL)
    return fail ("create");
  fill (buffer, length, 0, 3);
  if (write (fd, buffer, length) != (ssize_t) length)
    return fail ("write");
  memset (buffer, 0, length);
  if (pread (fd, buffer, length, 0) != (ssize_t) length)
    return fail ("pread");
  return check (buffer, length, 0, 3);
}

/* Data written through one mapping is there in the next one.  */
static int
unmap_and_remap (void)
{
  char path[4096];
  size_t length = PAGES * page_size;
  int fd = new_file (0, path, sizeof path);
  if (fd < 0 || ftruncate (fd, length) < 0)
    return fail ("create");
  unsigned char *map = mmap (NULL, length, PROT_READ | PROT_WRITE,
                             MAP_SHARED, fd, 0);
  if (map == MAP_FAILED)
    return fail ("mmap");
  fill (map, length, 0, 4);
  munmap (map, length);
  map = mmap (NULL, length, PROT_READ, MAP_SHARED, fd, 0);
  if (map == MAP_FAILED)
    return fail ("mmap again");
  return check (map, length, 0, 4);
}

/* Shrinking an open unlinked file and growing it again leaves zeros in
   the regrown part, whether read or mapped.  */
static int
shrink_and_regrow (int keep_link)
{
  char path[4096];
  size_t length = 2 * page_size, kept = 10;
  unsigned char *buffer = malloc (length);
  int fd = new_file (keep_link, path, sizeof path);
  if (fd < 0 || buffer == NULL || ftruncate (fd, length) < 0)
    return fail ("create");
  unsigned char *map = mmap (NULL, length, PROT_READ | PROT_WRITE,
                             MAP_SHARED, fd, 0);
  if (map == MAP_FAILED)
    return fail ("mmap");
  memset (map, 'A', length);
  if (ftruncate (fd, kept) < 0 || ftruncate (fd, length) < 0)
    return fail ("ftruncate");
  if (pread (fd, buffer, length, 0) != (ssize_t) length)
    return fail ("pread");
  for (size_t i = 0; i < length; i++)
    if (buffer[i] != (i < kept ? 'A' : 0) || map[i] != buffer[i])
      {
        fprintf (stderr, "# byte %zu: read %u, mapped %u\n", i, buffer[i],
                 map[i]);
        return 1;
      }
  if (keep_link)
    unlink (path);
  return 0;
}

/* msync has nothing to write for memory that only the default pager
   backs, and must not lose it: the data stays, in the mapping and for
   read, pages that were never touched still read as zeros, and the
   mapping takes new writes.  With FILE_BACKED the memory is an unlinked
   file of DIRECTORY, otherwise anonymous shared memory.  */
static int
msync_keeps_data (int file_backed)
{
  char path[4096];
  size_t length = 4 * page_size, used = length - page_size;
  unsigned char *buffer = malloc (length);
  int fd = -1;
  if (buffer == NULL)
    return fail ("malloc");
  if (file_backed)
    {
      fd = new_file (0, path, sizeof path);
      if (fd < 0 || ftruncate (fd, length) < 0)
        return fail ("create");
    }
  unsigned char *map = mmap (NULL, length, PROT_READ | PROT_WRITE,
                             MAP_SHARED | (file_backed ? 0 : MAP_ANONYMOUS),
                             fd, 0);
  if (map == MAP_FAILED)
    return fail ("mmap");
  fill (map, used, 0, 5);
  if (msync (map, length, MS_SYNC) < 0)
    return fail ("msync (MS_SYNC)");
  if (check (map, used, 0, 5))
    return 1;
  if (msync (map, length, MS_SYNC | MS_INVALIDATE) < 0)
    return fail ("msync (MS_SYNC | MS_INVALIDATE)");
  if (check (map, used, 0, 5))
    return 1;
  if (file_backed)
    {
      if (pread (fd, buffer, length, 0) != (ssize_t) length)
        return fail ("pread");
      if (check (buffer, used, 0, 5))
        return 1;
    }
  for (size_t i = used; i < length; i++)
    if (map[i] != 0)
      {
        fprintf (stderr, "# untouched byte %zu is %u\n", i, map[i]);
        return 1;
      }
  fill (map, length, 0, 6);
  return check (map, length, 0, 6);
}

/* A page that lies wholly beyond the end of the file faults (SIGBUS).  */
static int
beyond_end_faults (void)
{
  char path[4096];
  size_t length = 2 * page_size;
  int fd = new_file (1, path, sizeof path);
  if (fd < 0 || ftruncate (fd, length) < 0)
    return fail ("create");
  unlink (path);
  volatile unsigned char *map = mmap (NULL, length, PROT_READ | PROT_WRITE,
                                      MAP_SHARED, fd, 0);
  if (map == MAP_FAILED)
    return fail ("mmap");
  map[page_size] = 1;
  if (ftruncate (fd, page_size) < 0)
    return fail ("ftruncate");
  signal (SIGBUS, SIG_DFL);
  pid_t child = fork ();
  if (child == 0)
    {
      (void) map[page_size];
      _exit (0);
    }
  int status;
  waitpid (child, &status, 0);
  if (WIFSIGNALED (status) && WTERMSIG (status) == SIGBUS)
    return 0;
  fprintf (stderr, "# reading beyond the end did not fault\n");
  return 1;
}

static unsigned long
free_blocks (void)
{
  struct statvfs st;
  if (statvfs (directory, &st) < 0)
    return 0;
  return st.f_bfree;
}

/* Many mapped-after-close cycles: each works, and the filesystem's free
   space is back where it was once the last mapping is gone.  */
static int
repeated_cycles (int cycles)
{
  unsigned long before = free_blocks ();
  for (int i = 0; i < cycles; i++)
    {
      char path[4096];
      size_t length = 4 * page_size + 123;
      int fd = new_file (0, path, sizeof path);
      if (fd < 0 || ftruncate (fd, length) < 0)
        return fail ("create");
      unsigned char *map = mmap (NULL, length, PROT_READ | PROT_WRITE,
                                 MAP_SHARED, fd, 0);
      if (map == MAP_FAILED)
        return fail ("mmap");
      close (fd);
      fill (map, length, 0, (unsigned) i);
      if (check (map, length, 0, (unsigned) i))
        {
          fprintf (stderr, "# cycle %d\n", i);
          return 1;
        }
      munmap (map, length);
    }
  /* A filesystem frees the blocks of an unlinked file once the kernel has
     let go of its memory object, which it does after munmap has
     returned: give that a moment.  */
  unsigned long after = free_blocks ();
  for (int wait = 0; after != before && wait < 500; wait++)
    {
      usleep (10000);
      after = free_blocks ();
    }
  if (after != before)
    {
      fprintf (stderr, "# free blocks: %lu before, %lu after\n", before,
               after);
      return 1;
    }
  return 0;
}

static void
run (const char *description, int (*test) (void))
{
  fflush (stdout);
  test_number++;
  const char *only = getenv ("TMPFS_SHM_ONLY");
  if (only != NULL && atoi (only) != test_number)
    {
      printf ("ok %d - %s # SKIP TMPFS_SHM_ONLY=%s\n", test_number,
              description, only);
      return;
    }
  pid_t child = fork ();
  if (child == 0)
    {
      signal (SIGBUS, bus_error);
      alarm (CASE_TIMEOUT);
      _exit (test () ? 1 : 0);
    }
  int status = 0;
  waitpid (child, &status, 0);
  if (WIFEXITED (status) && WEXITSTATUS (status) == 0)
    printf ("ok %d - %s\n", test_number, description);
  else
    {
      failures++;
      printf ("not ok %d - %s%s\n", test_number, description,
              WIFEXITED (status) && WEXITSTATUS (status) == SIGBUS_EXIT
              ? " (SIGBUS)"
              : WIFSIGNALED (status) && WTERMSIG (status) == SIGALRM
              ? " (timed out)" : "");
    }
}

static int cycles = 100;

static int shrink_unlinked (void) { return shrink_and_regrow (0); }
static int shrink_linked (void) { return shrink_and_regrow (1); }
static int many_cycles (void) { return repeated_cycles (cycles); }
static int msync_file (void) { return msync_keeps_data (1); }
static int msync_anonymous (void) { return msync_keeps_data (0); }

static const struct
{
  const char *description;
  int (*test) (void);
} cases[] = {
  { "an unlinked file's mapping survives close", mapped_after_close },
  { "an anonymous shm_open object's mapping survives close", shm_object },
  { "write then read an unlinked file", write_read_unlinked },
  { "data survives unmapping and mapping again", unmap_and_remap },
  { "a page beyond the end of the file faults", beyond_end_faults },
  { "repeated cycles work and give the space back", many_cycles },
  { "shrink and regrow an unlinked file: zeros past the cut",
    shrink_unlinked },
  { "shrink and regrow a linked mapped file: zeros past the cut",
    shrink_linked },
  { "msync keeps the data of a mapped file", msync_file },
  { "msync keeps the data of anonymous shared memory", msync_anonymous },
};

int
main (int argc, char **argv)
{
  if (argc < 2 || argc > 3 || (argc == 3 && (cycles = atoi (argv[2])) < 1))
    {
      fprintf (stderr, "usage: tmpfs-shm DIRECTORY [CYCLES]\n");
      return 2;
    }
  directory = argv[1];
  page_size = (size_t) sysconf (_SC_PAGESIZE);
  size_t count = sizeof cases / sizeof cases[0];
  printf ("TAP version 13\n1..%zu\n", count);
  for (size_t i = 0; i < count; i++)
    run (cases[i].description, cases[i].test);
  return failures != 0;
}
