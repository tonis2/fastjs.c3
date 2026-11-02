// export * as: a module's namespace under one name, alongside a plain re-export.
export * as maths from './math.mjs';
export * as "string name" from './math.mjs';
export { aValue } from './reexport.mjs';
