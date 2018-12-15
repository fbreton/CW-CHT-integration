# Push CloudWatch mem and disk metrics to CHT

The presented script and CloudWatch agent config files has been tested with CloudWatch agent version 1.206336.0 and ruby 2.5.1p57. You can find all information to install, configure and start CloudWatch agent at https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Agent-on-first-instance.html

The scripts work in conjonction with specific measurement setup in the CloudWatch agent configuration files:
  https://github.com/fbreton/CW-CHT-integration/blob/master/LinuxCWconfig.json
  https://github.com/fbreton/CW-CHT-integration/blob/master/WindowsCWconfig.json
  
The usage can be extended to other metrics than the % of used memory and disk but might need some adaptation. 
