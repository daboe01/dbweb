/**
 * @author Ryan Johnson <http://syntacticx.com/>
 * @copyright 2008 PersonalGrid Corporation <http://personalgrid.com/>
 * @package LivePipe UI
 * @license MIT
 * @url http://livepipe.net/extra/hotkey
 * @require prototype.js, livepipe.js
 */

if(typeof(Prototype) == "undefined")
	throw "HotKey requires Prototype to be loaded.";
if(typeof(Control) == 'undefined')
	Control = {};
	
var $proc = function(proc){
	return typeof(proc) == 'function' ? proc : function(){return proc};
};

var $value = function(value){
	return typeof(value) == 'function' ? value() : value;
};
Object.Event = {
	extend: function(object){
		object._objectEventSetup = function(event_name){
			this._observers = this._observers || {};
			this._observers[event_name] = this._observers[event_name] || [];
		};
		object.observe = function(event_name,observer){
			if(typeof(event_name) == 'string' && typeof(observer) != 'undefined'){
				this._objectEventSetup(event_name);
				if(!this._observers[event_name].include(observer))
					this._observers[event_name].push(observer);
			}else
				for(var e in event_name)
					this.observe(e,event_name[e]);
		};
		object.stopObserving = function(event_name,observer){
			this._objectEventSetup(event_name);
			if(event_name && observer)
				this._observers[event_name] = this._observers[event_name].without(observer);
			else if(event_name)
				this._observers[event_name] = [];
			else
				this._observers = {};
		};
		object.observeOnce = function(event_name,outer_observer){
			var inner_observer = function(){
				outer_observer.apply(this,arguments);
				this.stopObserving(event_name,inner_observer);
			}.bind(this);
			this._objectEventSetup(event_name);
			this._observers[event_name].push(inner_observer);
		};
		object.notify = function(event_name){
			this._objectEventSetup(event_name);
			var collected_return_values = [];
			var args = $A(arguments).slice(1);
			try{
				for(var i = 0; i < this._observers[event_name].length; ++i)
					collected_return_values.push(this._observers[event_name][i].apply(this._observers[event_name][i],args) || null);
			}catch(e){
				if(e == $break)
					return false;
				else
					throw e;
			}
			return collected_return_values;
		};
		if(object.prototype){
			object.prototype._objectEventSetup = object._objectEventSetup;
			object.prototype.observe = object.observe;
			object.prototype.stopObserving = object.stopObserving;
			object.prototype.observeOnce = object.observeOnce;
			object.prototype.notify = function(event_name){
				if(object.notify){
					var args = $A(arguments).slice(1);
					args.unshift(this);
					args.unshift(event_name);
					object.notify.apply(object,args);
				}
				this._objectEventSetup(event_name);
				var args = $A(arguments).slice(1);
				var collected_return_values = [];
				try{
					if(this.options && this.options[event_name] && typeof(this.options[event_name]) == 'function')
						collected_return_values.push(this.options[event_name].apply(this,args) || null);
					for(var i = 0; i < this._observers[event_name].length; ++i)
						collected_return_values.push(this._observers[event_name][i].apply(this._observers[event_name][i],args) || null);
				}catch(e){
					if(e == $break)
						return false;
					else
						throw e;
				}
				return collected_return_values;
			};
		}
	}
};

var HotKey = Class.create({
	initialize: function(letter,callback,options){
		letter = letter.toUpperCase();
		HotKey.hotkeys.push(this);
		this.options = Object.extend({
			element: false,
			shiftKey: false,
			altKey: false,
			ctrlKey: true
		},options || {});
		this.letter = letter;
		this.callback = callback;
		this.element = $(this.options.element || document);
		this.handler = function(event){
			if(!event || (
				(Event['KEY_' + this.letter] || this.letter.charCodeAt(0)) == event.keyCode &&
				((!this.options.shiftKey || (this.options.shiftKey && event.shiftKey)) &&
					(!this.options.altKey || (this.options.altKey && event.altKey)) &&
					(!this.options.ctrlKey || (this.options.ctrlKey && (event.ctrlKey || event.metaKey)))
				)
			)){
				if(this.notify('beforeCallback',event) === false)
					return;
				this.callback(event);
				this.notify('afterCallback',event);
			}
		}.bind(this);
		this.enable();
	},
	trigger: function(){
		this.handler();
	},
	enable: function(){
		this.element.observe('keydown',this.handler);
	},
	disable: function(){
		this.element.stopObserving('keydown',this.handler);
	},
	destroy: function(){
		this.disable();
		HotKey.hotkeys = Control.HotKey.hotkeys.without(this);
	}
});
Object.extend(HotKey,{
	hotkeys: []
});
Object.Event.extend(HotKey);