#ifndef CONTAINER_H
# define CONTAINER_H

# include <sys/types.h>

# define CONTAINER_STATUS_CREATED	0
# define CONTAINER_STATUS_RUNNING	1
# define CONTAINER_STATUS_STOPPED	2

typedef struct s_container
{
	char	*id;
	char	*rootfs;
	char	**argv;
	pid_t	init_pid;
	int		status;
}	t_container;

int		cmd_run(char **argv);
int		cmd_ps(int argc, char **argv);
int		cmd_stop(int argc, char **argv);
int		cmd_rm(int argc, char **argv);
void	print_usage(void);

#endif
