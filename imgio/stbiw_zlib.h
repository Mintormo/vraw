// Прототип zlib-компрессора stb_image_write: в stb_image_write.h он
// объявлен только в части реализации (STB_IMAGE_WRITE_IMPLEMENTATION),
// а V пишет прототип для `fn C.` не всегда (с 0.5.2 1b4ecb9 - только в
// модуле с #flag библиотеки). Без прототипа gcc считает, что функция
// возвращает int, и обрезает указатель до 32 бит - падение в tiff.v.
unsigned char *stbi_zlib_compress(unsigned char *data, int data_len, int *out_len, int quality);
