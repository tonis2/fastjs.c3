// Decorated classes in each export form.
export const seen = [];
function note(cls, ctx) {
	seen.push(ctx.name);
	return class extends cls {
		static noted = true;
	};
}
@note export class Before {}
export @note class After {}
export default @note class Default {}
