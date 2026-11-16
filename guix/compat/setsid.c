/* setsid: run a program in a new session, like util-linux's setsid.  */
#include <stdio.h>
#include <unistd.h>

int
main (int argc, char *argv[])
{
  if (argc < 2)
    {
      fprintf (stderr, "usage: setsid PROGRAM [ARGUMENT...]\n");
      return 1;
    }
  /* A process group leader cannot start a session: continue in a child,
     and let the parent return at once, as util-linux's setsid does.  */
  if (getpgrp () == getpid ())
    {
      pid_t pid = fork ();
      if (pid < 0)
        {
          perror ("setsid: fork");
          return 1;
        }
      if (pid > 0)
        return 0;
    }
  if (setsid () < 0)
    {
      perror ("setsid");
      return 1;
    }
  execvp (argv[1], argv + 1);
  perror ("setsid: exec");
  return 127;
}
