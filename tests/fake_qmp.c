/* Minimal synthetic QMP server for tests/qmp.t. No real VM is involved. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int write_all(int fd, const char *text) {
    size_t left = strlen(text);
    while (left) {
        ssize_t count = write(fd, text, left);
        if (count < 0) return -1;
        text += count;
        left -= (size_t)count;
    }
    return 0;
}

static int reply(int fd, const char *id, const char *command) {
    char response[4096];
    if (strcmp(command, "unknown") == 0)
        snprintf(response, sizeof(response), "{\"id\":\"%s\",\"error\":{\"class\":\"GenericError\",\"desc\":\"unknown command\"}}\n", id);
    else if (strcmp(command, "query-status") == 0)
        snprintf(response, sizeof(response), "{\"id\":\"%s\",\"return\":{\"running\":true,\"status\":\"running\"}}\n", id);
    else
        snprintf(response, sizeof(response), "{\"id\":\"%s\",\"return\":{}}\n", id);
    return write_all(fd, response);
}

static int screenshot(const char *request) {
    const char *key = strstr(request, "\"filename\"");
    if (!key) return -1;
    key = strchr(key, ':');
    if (!key) return -1;
    key = strchr(key, '"');
    if (!key) return -1;
    const char *end = strchr(++key, '"');
    if (!end) return -1;
    char path[4096];
    size_t size = (size_t)(end - key);
    if (size >= sizeof(path)) return -1;
    memcpy(path, key, size);
    path[size] = '\0';
    FILE *file = fopen(path, "wb");
    if (!file) return -1;
    fputs("P6\n2 2\n255\n", file);
    const unsigned char pixels[] = { 0, 0, 0, 255, 0, 0, 0, 255, 0, 255, 255, 255 };
    fwrite(pixels, 1, sizeof(pixels), file);
    return fclose(file);
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (listener < 0 || strlen(argv[1]) >= sizeof(address.sun_path)) return 3;
    strcpy(address.sun_path, argv[1]);
    unlink(address.sun_path);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) < 0 || listen(listener, 16) < 0) return 4;
    puts("ready");
    fflush(stdout);
    while (1) {
        int connection = accept(listener, NULL, NULL);
        if (connection < 0) return 5;
        if (write_all(connection, "{\"QMP\":{}}\n") < 0) return 6;
        FILE *input = fdopen(dup(connection), "r");
        if (!input) return 7;
        char *line = NULL;
        size_t capacity = 0;
        ssize_t length;
        while ((length = getline(&line, &capacity, input)) >= 0) {
            if (length == 0) continue;
            FILE *requests = fopen(argv[2], "a");
            if (!requests) return 8;
            fputs(line, requests);
            fclose(requests);
            const char *id = strstr(line, "\"id\"");
            char id_text[128] = "request";
            if (id && (id = strchr(id, ':')) && (id = strchr(id, '"'))) {
                id++;
                size_t size = strcspn(id, "\"");
                if (size >= sizeof(id_text)) return 9;
                memcpy(id_text, id, size);
                id_text[size] = '\0';
            }
            const char *command = "other";
            if (strstr(line, "no-such-command")) command = "unknown";
            else if (strstr(line, "query-status")) command = "query-status";
            if (strstr(line, "\"screendump\"") && screenshot(line) < 0) return 10;
            if (reply(connection, id_text, command) < 0) return 11;
        }
        free(line);
        fclose(input);
        close(connection);
    }
}
