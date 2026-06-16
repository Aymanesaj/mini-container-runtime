#define _GNU_SOURCE

#include "container.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int	cmd_run(char **argv)
{
	char	*rootfs;
	char	**cmd_argv;

	rootfs = argv[0];
	cmd_argv = &argv[1];
	if (!rootfs || !cmd_argv[0])
	{
		fprintf(stderr,
			"usage: minictl run <rootfs> <command> [args...]\n");
		return (1);
	}
	if (access(rootfs, F_OK) != 0)
	{
		perror(rootfs);
		return (1);
	}
	if (chroot(rootfs) != 0)
	{
		perror("chroot");
		return (1);
	}
	if (chdir("/") != 0)
	{
		perror("chdir");
		return (1);
	}
	execve(cmd_argv[0], cmd_argv, environ);
	perror(cmd_argv[0]);
	return (1);
}
