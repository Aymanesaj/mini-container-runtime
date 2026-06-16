#include "container.h"

#include <stdio.h>

void	print_usage(void)
{
	printf("usage: minictl <command> [args...]\n\n");
	printf("commands:\n");
	printf("  run <rootfs> <command> [args...]  Run a command inside rootfs\n");
	printf("  ps                                  List containers (not yet implemented)\n");
	printf("  stop <id>                           Stop a container (not yet implemented)\n");
	printf("  rm <id>                             Remove a container (not yet implemented)\n");
	printf("  help                                Show this help\n");
}

int	cmd_ps(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	fprintf(stderr, "minictl ps: not yet implemented\n");
	return (1);
}

int	cmd_stop(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	fprintf(stderr, "minictl stop: not yet implemented\n");
	return (1);
}

int	cmd_rm(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	fprintf(stderr, "minictl rm: not yet implemented\n");
	return (1);
}
