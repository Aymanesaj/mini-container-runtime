NAME	= minictl
CC		= cc
CFLAGS	= -Wall -Wextra -Werror -Iinclude

SRCS	= src/main.c \
		  src/run.c \
		  src/cmd_stub.c

OBJS	= $(SRCS:.c=.o)

.PHONY: all clean debug release

all: debug

debug: CFLAGS += -g
debug: $(NAME)

release: CFLAGS += -O2 -DNDEBUG
release: $(NAME)

$(NAME): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS)

fclean: clean
	rm -f $(NAME)

re: fclean all