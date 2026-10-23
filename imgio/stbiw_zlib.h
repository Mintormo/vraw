// Прототип zlib-компрессора stb_image_write: в stb_image_write.h он
// объявлен только в части реализации (STB_IMAGE_WRITE_IMPLEMENTATION).
// `fn C.` в V - только сигнатура, объявление даёт заголовок (свой прототип
// V пишет лишь в модуле, линкующем библиотеку #flag без заголовков; раньше
// так и работало - из-за #flag -lm). Без прототипа gcc считает, что
// функция возвращает int, и обрезает указатель до 32 бит - падение.
unsigned char *stbi_zlib_compress(unsigned char *data, int data_len, int *out_len, int quality);
