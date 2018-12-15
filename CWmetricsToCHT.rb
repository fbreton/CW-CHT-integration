#!/usr/bin/env ruby
require 'aws-sdk'
require 'yaml'
require 'time'
require 'rest-client'
require 'json'


CONFIG_FILE = "./AWSmetrics.conf"


####
#
# Load the config file and check that all expected paramaters are present
#
####
def config_file(file_name)
  begin
    file = File.open(file_name, "r")
    params = Hash[file.each_line.map { |l| l.chomp.split('=', 2).collect(&:strip) }]
    file.close
    params.key?("AWSAccessKeyId") || raise("AWSAccessKeyId is missing in config file")
    params.key?("AWSSecretKey") || raise("AWSSecretKey is missing in config file")
    params.key?("CHTAPIKey") || raise("CHTAPIKey is missing in config file")
    params.key?("AWSRegions") || raise("AWSRegions is missing in config file")
    params.key?("MetricNameSpaces") || raise("MetricNameSpace is missing in config file")
    params.key?("MetricList") || raise("MetricList is missing in config file")
    params.key?("StartTime") || raise("StartTime is missing in config file")
    return params
  rescue Errno::ENOENT => e
    $stderr.puts "Caught the exception: #{e}"
    exit -1
  end
end

####
#
# Get the custom metrics from AWS and format the data for it can be injected in
# CHT metrics API
#
####
def get_push_metrics(region, accesskey, secretkey, chtkey, starttime, endtime, namespace,metriclist)
    ec2 = Aws::EC2::Client.new(region: region,
        access_key_id: accesskey,
        secret_access_key: secretkey)

    cw = Aws::CloudWatch::Client.new(region: region,
        access_key_id: accesskey,
        secret_access_key: secretkey)

    # get the metrics from AWS Cloudwatch
    list_metrics_output = cw.list_metrics({namespace: namespace})

    metricoutput = {"metrics": {"datasets": []}}
    metind = 0

    # format the metrics for it can be injected in CHT API
    list_metrics_output.metrics.each do |metric|

        if metriclist.include?(metric.metric_name) and (metric.dimensions.length == 1)
            
            assetid = region + ":" + ec2.describe_instances({instance_ids: [metric.dimensions[0].value]}).reservations[0].owner_id + ":" + metric.dimensions[0].value
            
           # We get an agregation of all file systems or logical disk. However, the metrics API require an fs path in the 
           # asset id, so we just arbitrary put the path to /
            if metric.metric_name[0..1] == "fs"
                assettype = "aws:ec2:instance:fs"
                assetid +=":/"
            else
                assettype = "aws:ec2:instance"
            end
            
           # For windows we can only get the logical disk free space percent, but we need the % used and 
           # we change the metric name to the expected value and we'll calculate the value later
            if metric.metric_name == "fs:free:percent"
                metname = "fs:used:percent"
            else
                metname = metric.metric_name
            end
          
           # get the metric from AWS from the specific name space agregated on 1hour
           # time frame as expected from CHT
            resp = cw.get_metric_data({
                metric_data_queries: [
                    {
                        id: "average",
                        metric_stat: {
                            metric: {
                                namespace: namespace,
                                metric_name: metric.metric_name,
                                dimensions: metric.dimensions
                            },
                            period: 3600,
                            stat: "Average",
                            }
                        },
                    {
                        id: "maximum",
                        metric_stat: {
                            metric: {
                                namespace: namespace,
                                metric_name: metric.metric_name,
                                dimensions: metric.dimensions
                            },
                            period: 3600,
                            stat: "Maximum",
                            }
                        },
                    {
                        id: "minimum",
                        metric_stat: {
                            metric: {
                                namespace: namespace,
                                metric_name: metric.metric_name,
                                dimensions: metric.dimensions
                            },
                            period: 3600,
                            stat: "Minimum",
                            }
                        }
                    ],
                start_time: starttime,
                end_time: endtime,
                scan_by: "TimestampAscending"
                })

            average = resp.metric_data_results[0]
            maximum = resp.metric_data_results[1]
            minimum = resp.metric_data_results[2]
            
          # build the header of the metric document as expected by CHT
            lg = average.timestamps.length - 1
            if lg > -1
                metricoutput[:metrics][:datasets][metind] = {"metadata": {
                    "assetType": assettype,"granularity": "hour",
                    "keys": [
                        "assetId","timestamp","#{metname}.avg",
                        "#{metname}.max","#{metname}.min"
                        ]},
                    "values": []
                    }
            end
           
          # build the values part of the document as expected by CHT 
            for i in (0..lg)
                timestamp = average.timestamps[i].strftime("%Y-%m-%dT%H:%M:%S%z").insert(-3,':')
              
              # For windows we can only get the logical disk free space percent, but we need the % used  
              # that we get with 100 - free % space
                if metric.metric_name == "fs:free:percent"
                    av = 100 - average.values[i]
                    max = 100 - maximum.values[i]
                    min = 100 - minimum.values[i]
                else
                    av = average.values[i]
                    max = maximum.values[i]
                    min = minimum.values[i]
                end
                metricoutput[:metrics][:datasets][metind][:values] << [
                    "#{assetid}", "#{timestamp}",
                    av.round(2),max.round(2),min.round(2)
                    ]
            end
            lg > -1 && metind += 1
        end
    end

    # inject the metrics in CHT
    if not metricoutput[:metrics][:datasets].empty?
        url = "https://chapi.cloudhealthtech.com/metrics/v1?api_key=#{chtkey}"
        resource = RestClient::Resource.new url, :timeout => 60, :open_timeout => 60
        response = resource.post metricoutput.to_json, :content_type => "application/json"
        if (response.code == 200)
            puts response
        else
            raise Exception, response.code.to_s + " error executing call"
        end
    end

end

def calc_end_time()
    endtime = Time.now
    year = endtime.year
    month = endtime.month
    day = endtime.day
    hour = endtime.hour
    min = endtime.min
    if ((min % 10) > 4) 
        min = (min - 5).round(-1)
    else
        min = min.round(-1)
    end
    endtime = Time.new(year,month,day,hour,min.round(-1),0)
    return endtime.strftime("%Y-%m-%dT%H:%M:00Z")
end

def update_conf_file(params,file_name)
    text = ''
    params.each do |k,v|
       text = text + k + '=' + v + "\n" 
    end
    file = File.open(file_name, "w")
    file.puts(text)
    file.close
end

# Read the conf file to get the params
params = config_file(CONFIG_FILE)
regions = params["AWSRegions"].split(',').collect(&:strip)
namespaces = params["MetricNameSpaces"].split(',').collect(&:strip)
metriclist = params["MetricList"].split(',').collect(&:strip)
endtime = calc_end_time()

# Get the data and push them to CHT for all regions and namespaces 
# defined on the conf file
regions.each do |region|
    namespaces.each do |namespace|
        get_push_metrics(region, params["AWSAccessKeyId"],params["AWSSecretKey"],params["CHTAPIKey"], params["StartTime"],endtime, namespace, metriclist)
    end
end

# Update the StarTime in the conf file for the next run
params["StartTime"] = endtime.gsub(/..:00Z/,"00:00Z")
update_conf_file(params, CONFIG_FILE)
