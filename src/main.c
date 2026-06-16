#include "container.h"

#include <stdio.h>
#include <string.h>

static int	dispatch(int argc, char **argv)
{
	if (argc < 2)
	{
		print_usage();
		return (1);
	}
	if (strcmp(argv[1], "run") == 0)
	{
		if (argc < 4)
		{
			fprintf(stderr,
				"usage: minictl run <rootfs> <command> [args...]\n");
			return (1);
		}
		return (cmd_run(&argv[2]));
	}
	if (strcmp(argv[1], "ps") == 0)
		return (cmd_ps(argc, argv));
	if (strcmp(argv[1], "stop") == 0)
		return (cmd_stop(argc, argv));
	if (strcmp(argv[1], "rm") == 0)
		return (cmd_rm(argc, argv));
	if (strcmp(argv[1], "help") == 0
		|| strcmp(argv[1], "--help") == 0
		|| strcmp(argv[1], "-h") == 0)
	{
		print_usage();
		return (0);
	}
	fprintf(stderr, "minictl: unknown command '%s'\n", argv[1]);
	print_usage();
	return (1);
}

int	main(int argc, char **argv)
{
	return (dispatch(argc, argv));
}
