// ComboBox subclass slightly modifies behaviour Ajax.Autocompleter towards combobox and fixes onblur bug
ComboBoxAutocompleter = Class.create(Ajax.Autocompleter,{
	initialize: function($super, element, url, options) {
		this.container=new Element('div', { 'class':'autocomplete', style: 'position:absolute;overflow-y:auto;z-index:1000;' });
		this.container.style.height=options.visibleHeight + "px";
		var update=new Element('div', {  style:'overflow:hidden;z-index:1000;' });
		if($(element).getWidth())
			update.style.width=($(element).getWidth()-19)+'px';	// platz fuer scroller
		this.container.appendChild(update);
		$(element).insert( {after: this.container} );
		if(!options.noPulldown)
		{	$(element).observe('click', this.activate.bindAsEventListener(this));
		}
		$(document).observe('click', this.hide.bindAsEventListener(this));
		$super(element, this.container, url, options);
	},
	getEntry: function(index) {
		return this.update.down().firstChild.childNodes[index];
	},
  	updateChoices: function(choices) {
		if(!this.changed && this.hasFocus) {
			this.update.down().innerHTML = choices;
			Element.cleanWhitespace(this.update.down());
			Element.cleanWhitespace(this.update.down().down());

			if(this.update.down().firstChild && this.update.down().down().childNodes) {
				this.entryCount = 
				this.update.down().down().childNodes.length;
				for (var i = 0; i < this.entryCount; i++) {
					var entry = this.getEntry(i);
					entry.autocompleteIndex = i;
					this.addObservers(entry);
				}
			} else { 
				this.entryCount = 0;
			}
			this.index = 0;

			if(this.entryCount==1 && this.options.autoSelect) {
				this.selectEntry();
				this.hide();
			} else {
				this.render();
			}
		}
	},
	selectEntry: function() {
		this.active = false;
		this.changed=true;
		this.updateElement(this.getCurrentEntry());
		if(this.options.onChange) this.options.onChange(this.element);
	},
	onObserverEvent: function() {
		this.changed = false;   
		this.tokenBounds = null;
		if(!this.options.noPulldown || this.getToken().length>=this.options.minChars) {
			this.getUpdatedChoices();
		} else {
			this.active = false;
			this.hide();
		}
		this.oldElementValue = this.element.value;
	},
	onBlur: function(event) {
		if(this.active && !this.changed && event ) $(event).stop();
		this.hasFocus = false;
		this.active = false;
	},
	onClick: function(event) {
		var element = Event.findElement(event, 'LI');
		this.index = element.autocompleteIndex;
		this.selectEntry();
		this.hide();
		if (this.options.afterClickElement) this.options.afterClickElement(this.element, element)
	}
});
