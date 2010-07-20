// 28.10.08 ProgressBar by Dr. Boehringer

ProgressBar = Class.create({
	initialize: function(element, width, seconds) {
		this.element=$(element);
		this.seconds=seconds;

		this.child = new Element('div', {className: 'progressbar', style: 'width:0px'} );
		this.child.innerHTML='&nbsp;';
		this.element.appendChild(this.child);

		this.element.className='progressbar_holder';
		this.element.style.display = "block";
		this.element.style.width = width+"px";

  		this.update(width/seconds, 1);
	},
	update: function(step, currentTime) {
		this.element.down().style.width = Math.ceil(step*currentTime) + "px";

		if(currentTime <= this.seconds)
		{	setTimeout(this.update.bind(this, step, currentTime+1), 1000);
		} else
		{	this.element.style.display = "none";
		}
	}
});
