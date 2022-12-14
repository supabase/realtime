export const removeFirst = (src: any[], element: any) => {
  const index = src.indexOf(element)
  if (index === -1) return src
  return [...src.slice(0, index), ...src.slice(index + 1)]
}
