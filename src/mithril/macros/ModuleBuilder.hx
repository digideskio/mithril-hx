package mithril.macros;

#if macro
import haxe.macro.Expr;
import haxe.macro.Context;
import haxe.macro.Type;

using haxe.macro.ExprTools;
using Lambda;
using StringTools;

class ModuleBuilder
{
	static var viewField : Function;

	// Types: 0 - Model, 1 - View, 2 - Controller/Component, 3 - Module(deprecated)
	@macro public static function build(type : Int) : Array<Field>
	{
		var c : ClassType = Context.getLocalClass().get();
		if (c.meta.has(":ModuleProcessed")) return null;
		c.meta.add(":ModuleProcessed",[],c.pos);

		var fields = Context.getBuildFields();

		function checkInvalidProp(f : Field) {
			if (Lambda.exists(f.meta, function(m) return m.name == "prop")) {
				Context.warning("@prop only works with var", f.pos);
			}
		}
		
		if(Context.defined('no-mithril-sugartags'))
			Context.warning('-D no-mithril-sugartags is deprecated, it is now disabled by default.', c.pos);

		for(field in fields) switch(field.kind) {
			case FFun(f):
				checkInvalidProp(field);
				if(f.expr == null) continue;

				if(Context.defined('mithril-sugartags'))
					replaceSugarTags(f.expr);

				// Set viewField if current field is the view function.
				// it will automatically return its content.
				if(field.name == "view") viewField = f;
				else viewField = null;

				replaceM(f.expr);
				returnLastMExpr(f);
				
				function keepField() {
					field.meta.push({
						pos: Context.currentPos(),
						params: null,
						name: ':keep'
					});					
				}

				if (type & 2 == 2 && field.name == "controller") {
					keepField();
					injectCurrentModule(f);
				}
				if ((type & 1 == 1 || type & 2 == 2) && field.name == "view") {
					keepField();
					#if (haxe_ver < 3.3)
					if(f.ret == null) {
						// Return Dynamic so multi-type arrays can be used in view without casting
						f.ret = macro : Dynamic;
					}
					#end
				} 
				if (type & 3 == 3 && field.name == "view") addViewArgument(f, Context.getLocalType());
				
			case FVar(t, e), FProp(_, _, t, e):
				var prop = field.meta.find(function(m) return m.name == "prop");
				if (prop == null) continue;

				field.kind = FVar(TFunction([TOptional(t)], t), e == null 
					? macro mithril.M.prop(null) 
					: macro mithril.M.prop($e));
		}

		return fields;
	}

	private static function replaceSugarTags(e : Expr) {
		//if(e.toString().indexOf('form-control') > 0) trace(e.expr);
		switch(e.expr) {
			// TAG[attr=value]
			case ECall({expr: EArray(e1, e2), pos: _}, params):
				var str = e1.toString() + '[' + e2.toString() + ']';
				replaceSugarTag(e, str, params);
			// TAG.class
			case EBinop(Binop.OpSub, e1, {expr: ECall(e2, params), pos: _}):
				var str = e1.toString() + '-' + e2.toString();
				replaceSugarTag(e, str, params);
			// TAG
			case ECall(e2, params):
				replaceSugarTag(e, e2.toString(), params);
			case _:
				e.iter(replaceSugarTags);
		}

	}

	private static var tagList = ["A","ABBR","ACRONYM","ADDRESS","AREA","ARTICLE","ASIDE","AUDIO","B","BDI","BDO","BIG","BLOCKQUOTE","BODY","BR","BUTTON","CANVAS","CAPTION","CITE","CODE","COL","COLGROUP","COMMAND","DATALIST","DD","DEL","DETAILS","DFN","DIV","DL","DT","EM","EMBED","FIELDSET","FIGCAPTION","FIGURE","FOOTER","FORM","FRAME","FRAMESET","H1","H2","H3","H4","H5","H6","HEAD","HEADER","HGROUP","HR","HTML","I","IFRAME","IMG","INPUT","INS","KBD","KEYGEN","LABEL","LEGEND","LI","LINK","MAP","MARK","META","METER","NAV","NOSCRIPT","OBJECT","OL","OPTGROUP","OPTION","OUTPUT","P","PARAM","PRE","PROGRESS","Q","RP","RT","RUBY","SAMP","SCRIPT","SECTION","SELECT","SMALL","SOURCE","SPAN","SPLIT","STRONG","STYLE","SUB","SUMMARY","SUP","TABLE","TBODY","TD","TEXTAREA","TFOOT","TH","THEAD","TIME","TITLE","TR","TRACK","TT","UL","VAR","VIDEO","WBR"];
	private static function replaceSugarTag(e : Expr, exprStr : String, params) {
		e.iter(replaceSugarTags);

		var dotPos = exprStr.indexOf('.'); if(dotPos == -1) dotPos = 10000;
		var brPos  = exprStr.indexOf('['); if(brPos == -1) brPos = 10000;
		var pos = Std.int(Math.min(dotPos, brPos));

		var test = pos != 10000 ? exprStr.substr(0, pos) : exprStr;

		if(Context.defined('lowercase-mithril-sugartags')) test = test.toUpperCase();

		if (tagList.has(test)) {
			// Convert tag to lowercase
			var outStr = test.toLowerCase() + exprStr.substr(test.length).replace(' ', '');			
			var newParams = [macro $v{outStr}].concat(params);
			e.expr = (macro mithril.M.m($a{newParams})).expr;
		}
	}

	private static function replaceM(e : Expr) {
		// Autocompletion for m()
		if (Context.defined("display")) switch e.expr {
			case EDisplay(e2, isCall):
				switch(e2) {
					case macro m:
						e2.expr = (macro mithril.M.m).expr;
						return;
					case _:
				}
			case _:
		}

		switch(e) {
			case macro M($a, $b, $c), macro m($a, $b, $c):
				e.iter(replaceM);
				e.expr = (macro mithril.M.m($a, $b, $c)).expr;
			case macro M($a, $b), macro m($a, $b):
				e.iter(replaceM);
				e.expr = (macro mithril.M.m($a, $b)).expr;
			case macro M($a), macro m($a):
				e.expr = (macro mithril.M.m($a)).expr;
			case _:
				e.iter(replaceM);
		}

		switch(e.expr) {
			case EFunction(_, f): returnLastMExpr(f);
			case _:
		}
	}

	/**
	 * Return the last m() call automatically, or an array with m() calls.
	 * Returns null if no expr exists.
	 */
	private static function returnLastMExpr(f : Function) {
		switch(f.expr.expr) {
			case EBlock(exprs):
				if (exprs.length > 0)
					returnMOrArrayMExpr(exprs[exprs.length - 1], f);
			case _:
				returnMOrArrayMExpr(f.expr, f);
		}
	}

	/**
	 * Add return to m() calls, or an Array with m() calls.
	 */
	private static function returnMOrArrayMExpr(e : Expr, f : Function) {
		switch(e.expr) {
			case EReturn(_):
			case EArrayDecl(values):
				if(values.length > 0 && f != viewField) 
					checkForM(values[0], e);
				else
					injectReturn(e);
			case _:
				if(f != viewField) checkForM(e, e);
				else injectReturn(e);
		}
	}

	/**
	 * Check if e is a m() call, then add return to inject
	 */
	private static function checkForM(e : Expr, inject : Expr) {
		switch(e) {
			case macro mithril.M.m($a, $b, $c):
			case macro mithril.M.m($a, $b):
			case macro mithril.M.m($a):
			case _: return;
		}

		injectReturn(inject);
	}

	private static function injectReturn(e : Expr) {
		e.expr = EReturn({expr: e.expr, pos: e.pos});
	}

	/**
	 * Add a "ctrl" argument to the view if no parameters exist.
	 */
	private static function addViewArgument(f : Function, t : Type) {
		if(f.args.length > 0) return;
		f.args.push({
			value: null,
			type: Context.toComplexType(t),
			opt: true,
			name: "ctrl"
		});
	}

	/**
	 * Mithril makes a "new component.controller()" call in m.mount and m.component which 
	 * complicates things. If the controller was called with one of those,
	 * M.__haxecomponents has stored the controller and will be used here.
	 * (instead of using a newly constructed function object)
	*/
	private static function injectCurrentModule(f : Function) {
		switch(f.expr.expr) {
			case EBlock(exprs):
				exprs.unshift(macro
					if(mithril.M.__haxecomponents.length && untyped !this.controller) {
						// Need to be untyped to avoid clashing with macros that modify return (particularly HaxeContracts)
						untyped __js__("return m.__haxecomponents.pop().controller()");
					}
				);
				exprs.push(macro return untyped this);
			case _:
				f.expr = {expr: EBlock([f.expr]), pos: f.expr.pos};
				injectCurrentModule(f);
		}
	}
}
#end
