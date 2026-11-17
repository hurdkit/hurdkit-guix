#ifndef HURDKIT_SCENE_H
#define HURDKIT_SCENE_H
#include <GLES2/gl2.h>
int scene_init(GLuint *program, GLuint *buffer);
void scene_draw(GLuint program, GLuint buffer);
#endif
