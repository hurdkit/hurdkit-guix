#include "scene.h"
#include <stdio.h>
#include <stdlib.h>

static GLuint shader(GLenum type, const char *source)
{
	GLuint s = glCreateShader(type);
	glShaderSource(s, 1, &source, NULL);
	glCompileShader(s);
	GLint ok;
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[2048];
		glGetShaderInfoLog(s, sizeof log, NULL, log);
		fprintf(stderr, "shader compilation: %s\n", log);
		exit(1);
	}
	return s;
}

int scene_init(GLuint *program, GLuint *buffer)
{
	const char *vs = "attribute vec2 position; attribute vec3 colour; "
		"varying vec3 v_colour; void main() { v_colour = colour; "
		"gl_Position = vec4(position, 0.0, 1.0); }";
	const char *fs = "precision mediump float; varying vec3 v_colour; "
		"void main() { gl_FragColor = vec4(v_colour, 1.0); }";
	GLuint v = shader(GL_VERTEX_SHADER, vs), f = shader(GL_FRAGMENT_SHADER, fs);
	*program = glCreateProgram();
	glAttachShader(*program, v); glAttachShader(*program, f);
	glBindAttribLocation(*program, 0, "position");
	glBindAttribLocation(*program, 1, "colour");
	glLinkProgram(*program);
	GLint ok;
	glGetProgramiv(*program, GL_LINK_STATUS, &ok);
	if (!ok) return -1;
	glDeleteShader(v); glDeleteShader(f);
	static const float vertices[] = {
		-0.6f, 0.65f, 0.75f, 0.12f, 0.12f,
		 0.6f, 0.65f, 0.12f, 0.75f, 0.12f,
		 0.0f,-0.65f, 0.12f, 0.12f, 0.75f
	};
	glGenBuffers(1, buffer);
	glBindBuffer(GL_ARRAY_BUFFER, *buffer);
	glBufferData(GL_ARRAY_BUFFER, sizeof vertices, vertices, GL_STATIC_DRAW);
	return 0;
}

void scene_draw(GLuint program, GLuint buffer)
{
	glViewport(0, 0, 640, 480);
	glClearColor(0.04f, 0.06f, 0.10f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glUseProgram(program);
	glBindBuffer(GL_ARRAY_BUFFER, buffer);
	glEnableVertexAttribArray(0);
	glEnableVertexAttribArray(1);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 5 * sizeof(float), (void *)0);
	glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 5 * sizeof(float),
			       (void *)(2 * sizeof(float)));
	glDrawArrays(GL_TRIANGLES, 0, 3);
}
