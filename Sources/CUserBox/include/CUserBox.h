#ifndef USERBOX_H
#define USERBOX_H
#include <stdint.h>
#include <stddef.h>
// Unix sockets only: no HTTP listener, authentication token, or network exposure.
int ub_listen(const char *path);
int ub_connect(const char *path);
int ub_accept(int fd);
int ub_peer_uid(int fd, uint32_t *uid);
int ub_read_exact(int fd, void *buffer, size_t count);
int ub_write_exact(int fd, const void *buffer, size_t count);
void ub_close(int fd);
int ub_set_timeout(int fd, int seconds);
uint32_t ub_uid(void);
uint32_t ub_process_uid(int pid);
uint32_t ub_console_uid(void);
int ub_secure_config(const char *path);
int ub_session(uint32_t *sid, uint32_t *uid, int *graphical, int *console, int *loggedIn);
#endif
